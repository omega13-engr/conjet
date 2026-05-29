# Conjet Implementation Plan

Status: planning artifact created from the shared ChatGPT context and current workspace inspection.

Workspace state on 2026-05-29: `/Users/sly/Workspace/Personal/conjet` is not a Git repository and had no project files before this plan, only ChumMem metadata. Treat this document as the initial technical plan, not as evidence that implementation has started.

## 1. Intent

Conjet is a macOS container runtime focused on light resource usage, low power usage, and high-performance developer workflows. The credible research claim is not "10x faster for every workload." The credible target is:

> Conjet aims for up to 10x faster filesystem-heavy development workflows and up to 2x lower idle power or energy-to-solution on selected workloads by moving hot work into native Linux storage and synchronizing only the files that matter.

This follows the shared chat context:

- macOS Linux containers still need Linux execution semantics, usually inside a Linux VM.
- OrbStack is already highly optimized, so universal 10x wins are not realistic.
- The largest exploitable bottleneck is host-to-guest filesystem crossing, especially many-small-file workloads.
- The best research direction is an adaptive filesystem/sync layer, predictive cache, file-watch bridge, and energy-aware VM scheduling.

## 2. Evidence Baseline

Primary facts that shape the plan:

- Apple Virtualization.framework is the correct low-level VM base for Linux VMs on macOS, with VIRTIO device support and Rosetta support for x86_64 Linux binaries on Apple Silicon. Apple also exposes host directories to Linux guests through VirtioFS-backed shared directories, requiring guest kernel support for `CONFIG_VIRTIO_FS`.[^apple-vz][^apple-shared][^apple-rosetta]
- Colima can use QEMU, VZ, or krunkit. Its docs list QEMU as the config default, and VZ as the better-performance Apple Virtualization.framework option with Rosetta and VirtioFS support. Its mount docs list `sshfs` as default, `9p` as better, and `virtiofs` as best when VZ/macOS requirements are met.[^colima-config]
- Lima v1.0+ uses VZ by default on macOS 13.5+ when compatible, but non-native architecture can still push the path toward QEMU.[^lima-vmtype] Lima's VirtioFS mount support uses Apple Virtualization.framework shared directories on macOS and requires macOS 13+ with `vmType: vz`.[^lima-mount]
- OrbStack documents a lightweight shared-kernel Linux VM architecture, custom purpose-built services, low-level VM tuning, VirtioFS plus custom file-sharing cache, forwarded Docker socket, and a custom virtual network stack.[^orbstack-architecture][^orbstack-files][^orbstack-network]
- Docker Desktop docs explicitly warn that sharing too many files can cause high CPU load and slow filesystem performance, and recommend storing non-code data such as caches and databases inside the Linux VM using volumes.[^docker-settings] Docker's Synchronized File Shares use a synchronized cache on ext4 inside the Docker Desktop VM, which validates the same general direction Conjet should take, but Conjet should make this a first-class adaptive default rather than an optional subscription feature.[^docker-sync]
- Apple has an open-source `containerization` Swift package for running Linux containers on macOS using Virtualization.framework, including OCI image management, ext4 filesystem creation, optimized kernels, lightweight VMs, and Rosetta support. It currently requires Apple Silicon, macOS 26, and Xcode 26 for building from source.[^apple-containerization]
- BuildKit already provides important build optimizations: parallel build graph solving, incremental transfer of changed build-context files, skipping unused stages/files, and cache management.[^buildkit] Conjet should integrate with BuildKit rather than reimplementing it.
- containerd supports remote snapshotters, which can support lazy image strategies through snapshotter-specific metadata and pull behavior.[^containerd-remote]

## 3. Non-Negotiable Design Goals

1. Light by default
   - No Electron dependency.
   - No always-heavy Kubernetes path.
   - VM boots only when required.
   - Idle daemon must be event-driven, not polling-driven.

2. Low power
   - Idle CPU target: at or below OrbStack-class idle behavior, measured on Apple Silicon.
   - Reduce wakeups, not just average CPU.
   - Track energy-to-solution, not only watts.

3. High performance
   - Optimize filesystem-heavy dev loops first.
   - Keep dependency folders, caches, databases, and build outputs inside Linux-native storage by default.
   - Use host synchronization only where human editing or source-of-truth semantics require it.

4. Faster than OrbStack and Colima where defensible
   - Baseline against OrbStack, Docker Desktop, Colima default, Colima tuned VZ + VirtioFS, and native Linux.
   - A claim is allowed only if the benchmark suite proves it.
   - CPU-bound workloads are expected to be near native and not a realistic 10x target.

5. Docker-compatible developer experience
   - `docker` and `docker compose` should work via a Conjet Docker socket bridge.
   - `conjet start`, `conjet stop`, `conjet status`, `conjet shell`, `conjet run`, and `conjet compose up` are the initial CLI surface.

## 4. Architecture

Initial architecture:

```text
conjet CLI
    |
    v
conjetd macOS daemon
    |  launchd + Unix socket/XPC control API
    v
Apple Virtualization.framework VM
    |  vsock control plane + virtio-net + virtio-blk + minimal VirtioFS bootstrap share
    v
minimal Linux guest
    |
    +-- containerd
    +-- BuildKit
    +-- runc
    +-- conjet-agent
    +-- conjetfs-agent
    |
    v
native Linux workspace volumes: ext4 first, btrfs/zfs experiments later
```

The initial runtime should be a shared dev VM, not one VM per container. A shared VM is the best first target for Docker Compose compatibility, low idle overhead, shared image cache, and simple Docker socket compatibility. A later "microVM lane" can use Apple's Containerization package for short-lived isolated commands if benchmarks justify it.

### Component Choices

- macOS daemon: Swift, because Virtualization.framework, launchd, powermetrics integration, app signing, and native low-power macOS behavior are first-class there.
- CLI: Swift first for one binary and shared types with `conjetd`. Add shell completions and JSON output early.
- Sync engine: Rust library/process if Swift filesystem/event performance becomes limiting. Start with Swift prototype, but design protocol boundaries so the sync engine can be swapped.
- Guest agent: Rust or Go static binary. It manages workspace placement, inotify/fanotify replay, containerd/BuildKit health, and guest-side metrics.
- Guest OS: minimal Linux image with custom kernel config. Start with Alpine or Buildroot for speed; keep a path to a custom optimized kernel.
- Runtime: containerd + BuildKit + runc. Avoid replacing these until Conjet has measured evidence of a runtime bottleneck.
- Networking: start with VZ NAT/bridged capabilities and event-based port forwarding; custom network stack only after filesystem and power wins are proven.

## 5. Core Research Algorithms

### 5.1 Adaptive Hot-Path Sync

Problem: live bind mounts force many container file operations to cross the macOS <-> Linux boundary.

Goal: classify each path and decide whether it belongs in host-synced storage, VM-native storage, lazy sync, ignored storage, or export-on-demand storage.

Initial placement policy:

```text
host-synced:
  src/, app/, lib/, config files, lockfiles, Dockerfile, compose files

VM-native:
  node_modules/, vendor/, target/, dist/, .next/, .turbo/, .cache/,
  database data, package manager caches, build outputs

lazy-synced:
  generated assets that developers inspect occasionally

ignored:
  temp files, editor swap files, logs, OS metadata, generated cache churn

export-on-demand:
  artifacts requested by user commands: conjet export, conjet open, conjet cp
```

Placement function:

```text
score(path) =
    w1 * source_relevance
  + w2 * host_edit_probability
  - w3 * write_churn
  - w4 * small_file_density
  - w5 * container_only_probability
  - w6 * rebuildable_artifact_probability

if score >= host_sync_threshold:
    host-synced
else if container_only_probability high:
    VM-native
else if human_inspection_probability moderate:
    lazy-synced
else:
    ignored or export-on-demand
```

Implementation details:

- Maintain a content-addressed index using path, inode, mtime, size, file mode, hash, and generation id.
- Use fast hashing such as BLAKE3 for changed files and directory Merkle roots.
- Use a write-ahead log for sync operations so VM/host interruptions can resume safely.
- Use `.conjetignore`, `.dockerignore`, `.gitignore`, language defaults, and learned access patterns.
- Record per-path telemetry locally: reads, writes, creates, deletes, rename churn, file size, and fanout count.
- Keep conflict handling conservative: source files are host-authoritative by default; VM-generated artifacts are VM-authoritative by default.

MVP constraint: Phase 1 only needs one-way host-to-VM sync plus VM-native dependency/build folders. Two-way sync comes later.

### 5.2 Smart File Watch Bridge

Problem: host editors use FSEvents; containers expect inotify/fanotify. Raw event propagation creates wakeups and duplicate work.

Algorithm:

```text
FSEvents batch window: 25-100 ms adaptive

for each event batch:
    normalize paths
    drop ignored/generated paths
    collapse duplicate writes and rename temp-file patterns
    prioritize hot-reload relevant source paths
    emit minimal inotify-compatible events to guest
```

Target outcome:

- A formatter that rewrites a file multiple times creates one meaningful guest event.
- Dependency install churn inside VM does not wake host watchers.
- Hot reload receives source changes quickly without syncing entire trees.

### 5.3 Conjet Energy Governor

Problem: container runtimes can burn battery through idle daemons, timers, watchers, memory pressure, and unnecessary CPU scheduling.

Governor states:

```text
cold:
  no VM, daemon waiting on user event

warm-idle:
  VM running, no active containers or builds

dev-idle:
  containers running, low request/file activity

interactive:
  hot reload, shell, HTTP requests, file edits

build:
  BuildKit/containerd/package manager heavy work

cooldown:
  recent work ended, delayed demotion to avoid thrash
```

Policy actions:

- Adjust VM vCPU limits and guest cgroups by state.
- Use memory ballooning or guest reclaim when supported.
- Reduce sync scanner cadence in idle states.
- Suspend noncritical prefetch and cache indexing when battery/thermal pressure is high.
- Batch filesystem events more aggressively in idle and on battery.
- Keep build mode performance-first but evaluate energy-to-solution.
- Stop inactive services after configurable quiet periods.

Metrics:

- `powermetrics` CPU power, wakeups, idle exits, thermal pressure where available.
- `ps`, `vm_stat`, `memory_pressure`, and Activity Monitor process data.
- guest `/proc/stat`, cgroup stats, containerd/buildkit metrics, sync queue length.

### 5.4 Predictive Build and Dependency Cache

Problem: generic Docker environments waste time rebuilding or redownloading predictable dependencies.

Project detectors:

- Node: `package.json`, `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`
- PHP: `composer.json`, `composer.lock`
- Rust: `Cargo.toml`, `Cargo.lock`
- Go: `go.mod`, `go.sum`
- Python: `pyproject.toml`, `uv.lock`, `poetry.lock`, `requirements.txt`
- Java: `pom.xml`, `build.gradle`, `gradle.lockfile`

Actions:

- Keep package caches in VM-native volumes.
- Generate BuildKit cache mount suggestions or inject opt-in templates.
- Prewarm registry mirrors and package metadata only when the project is active.
- Use lockfile hashes as cache keys.
- Prune by LRU, project importance, disk pressure, and energy state.

### 5.5 Image Startup and Lazy Layer Experiments

Start with normal containerd pull/unpack for correctness. Add experiments after the runtime is stable:

- containerd remote snapshotter path.
- eStargz or Nydus experiments for time-to-first-process.
- local registry mirror.
- zstd-compressed layer cache where compatible.
- prefetch only files touched by prior runs.

Do not make lazy pull a core MVP dependency; it is a phase-two optimization.

## 6. Phased Roadmap

### Phase 0: Benchmark Harness Before Runtime

Deliverables:

- `bench/` scripts for repeatable workloads.
- Machine profile capture: macOS version, chip, RAM, power state, thermal state.
- Baselines for OrbStack, Colima default, Colima tuned VZ + VirtioFS, Docker Desktop, and native Linux if available.
- Result schema: JSON plus Markdown report.

Workloads:

- Empty container start.
- Docker Compose start.
- `npm install`, `pnpm install`, `composer install`.
- `cargo build`, `go test ./...`.
- Next.js and Laravel/Symfony hot reload.
- many-small-file `fio`/`fs_mark`.
- image build with cache and without cache.
- database volume write workload.
- idle 10-minute power sample.

Exit gate:

- Harness can run the same workload against at least Colima tuned and one incumbent runtime.
- It records duration, CPU, memory, disk, wakeups, and available power samples.

### Phase 1: Skeleton Runtime

Deliverables:

- SwiftPM workspace.
- `conjet` CLI with `start`, `stop`, `status`, `doctor`.
- `conjetd` launchd-compatible daemon.
- Config at `~/.conjet/config.toml`.
- Local control socket at `~/.conjet/run/conjetd.sock`.
- Structured logs and JSON status output.

Exit gate:

- Daemon starts and stops cleanly.
- CLI can report host capabilities: Apple Silicon, macOS version, Virtualization.framework availability, Rosetta availability, required entitlements.

### Phase 2: Minimal VZ Linux VM

Deliverables:

- Boot minimal Linux VM with VZ.
- vsock control channel.
- serial console logs.
- virtio-blk root disk and data disk.
- minimal bootstrap VirtioFS share for guest agent install/update only.
- `conjet shell`.

Exit gate:

- Cold boot P50 and P95 measured.
- VM idle CPU and memory measured.
- VM survives stop/start cycle without disk corruption.

### Phase 3: Guest Container Runtime

Deliverables:

- containerd, runc, BuildKit inside guest.
- Docker-compatible socket bridge from macOS to guest.
- `conjet run IMAGE CMD`.
- `conjet compose up` as a wrapper over Docker Compose using Conjet socket.
- Image cache stored on guest-native disk.

Exit gate:

- `docker --host unix://~/.conjet/run/docker.sock run hello-world` works.
- `docker compose up` works for a small multi-service project.
- Conjet can be benchmarked against Colima on container startup and Compose startup.

### Phase 4: ConjetFS MVP

Deliverables:

- `conjet project init` and `conjet project attach`.
- One-way host-to-VM sync.
- `.conjetignore`.
- VM-native dependency/build/cache paths.
- Native Linux workspace mount path inside containers.
- Initial path classifier for Node, PHP, Rust, Go, Python.

Exit gate:

- `npm install` and `pnpm install` run with `node_modules` inside VM-native storage by default.
- Source edits on macOS appear in the VM workspace.
- Dependency churn does not sync back to host.
- Benchmark shows a clear win over bind-mount-heavy workflows before expanding scope.

### Phase 5: Watch Bridge and Two-Way Semantics

Deliverables:

- FSEvents-to-inotify bridge.
- Event compression and prioritization.
- Safe two-way sync for selected generated outputs.
- Conflict detection and conservative resolution.
- `conjet sync status`, `conjet sync repair`, `conjet sync export`.

Exit gate:

- Hot reload works for representative Next.js and PHP projects.
- Duplicate event rate and wakeup rate are measured.
- Conflict scenarios are covered by tests.

### Phase 6: Cache and Image Acceleration

Deliverables:

- Project cache policy engine.
- Package-manager cache volumes.
- BuildKit cache configuration profiles.
- Registry mirror option.
- Optional remote/lazy snapshotter experiment.

Exit gate:

- Repeat builds show cache hit improvements.
- Cache pruning is deterministic and respects disk pressure.
- Lazy snapshotter remains optional until reliability is proven.

### Phase 7: Energy Governor

Deliverables:

- State machine: cold, warm-idle, dev-idle, interactive, build, cooldown.
- Resource policy engine.
- VM/container activity detector.
- Low-power mode awareness.
- `conjet power report`.

Exit gate:

- Idle power/wakeups are below Colima and competitive with OrbStack on the same machine.
- At least one filesystem-heavy workload shows lower energy-to-solution than OrbStack or tuned Colima.
- Governor changes do not degrade interactive latency beyond a defined threshold.

### Phase 8: Hardening, UX, and Distribution

Deliverables:

- Signed and notarized macOS app/CLI package.
- Entitlements audit.
- VM image signing and update channel.
- Migration from Docker Desktop/Colima contexts.
- Security model documentation.
- Crash reporting optional and telemetry-free by default.

Exit gate:

- Clean install and uninstall.
- No privileged helper unless strictly required.
- End-to-end benchmark report included in release artifacts.

## 7. Benchmark Acceptance Criteria

Conjet cannot claim "faster than OrbStack and Colima" until this matrix is green:

| Area | Minimum credible target | Stretch target |
| --- | --- | --- |
| Cold VM start | Faster than Colima tuned | OrbStack-class seconds |
| Empty container start | Faster than Colima tuned | Competitive with OrbStack |
| npm/pnpm install | 2x faster than tuned bind mount path | Up to 10x on bad bind-mount baselines |
| Composer install | 2x faster than tuned bind mount path | Up to 10x on bad bind-mount baselines |
| Hot reload latency | Equal or faster than OrbStack | Lower CPU wakeups than OrbStack |
| Idle CPU | Lower than Colima default/tuned | OrbStack-class idle |
| Idle power | Lower than Colima default/tuned | 2x lower than OrbStack only if measured |
| Energy-to-solution | Lower than Colima tuned | 2x lower than OrbStack on selected workloads |
| Network throughput | Good enough for dev | Competitive with OrbStack after custom net work |

Rules:

- Report P50, P95, and variance.
- Record thermal state and whether the Mac is plugged in.
- Separate cold-cache and warm-cache results.
- Do not compare against misconfigured Colima only; include tuned VZ + VirtioFS.
- Publish failed benchmarks too, because they decide next work.

## 8. Test Strategy

Unit tests:

- path classifier
- ignore parser
- Merkle tree/index
- sync journal replay
- conflict resolver
- governor state transitions
- cache-key derivation

Integration tests:

- VM boot and shutdown
- guest agent handshake
- Docker socket forwarding
- one-way sync correctness
- dependency folder isolation
- Compose lifecycle
- file-watch event replay

Stress tests:

- 1 million tiny files
- rename storms
- editor temp-file churn
- interrupted sync
- disk-full behavior
- VM power loss
- network loss during image pull

Performance tests:

- hyperfine command suites
- fio/fs_mark filesystem suites
- BuildKit cache tests
- powermetrics idle and active samples

## 9. Repository Layout to Create During Implementation

```text
conjet/
  Package.swift
  Sources/
    ConjetCLI/
    ConjetDaemon/
    ConjetCore/
    ConjetVZ/
    ConjetPower/
  guest/
    agent/
    image/
    kernel/
  conjetfs/
    README.md
    src/
  bench/
    workloads/
    runners/
    reports/
  docs/
    architecture.md
    benchmark-methodology.md
    power-methodology.md
    security-model.md
```

## 10. Key Risks

- OrbStack is already optimized. Beating it broadly may be impossible; target narrow workloads and prove them.
- Docker Desktop's Synchronized File Shares validate the sync-cache approach but also raise the competitive bar.
- Two-way sync can corrupt user data if rushed. Start with host-authoritative source sync and explicit artifact export.
- File watching semantics are hard across FSEvents and inotify. Prefer conservative correctness over clever event replay.
- Rosetta support is useful but should not become the default fast path. Prefer native arm64 containers.
- A custom network stack is expensive. Defer until filesystem and power improvements are proven.
- Benchmark noise on laptops is high. Require controlled thermal/power conditions and repeated samples.

## 11. Immediate Next Implementation Steps

1. Create the SwiftPM skeleton and CLI/daemon IPC.
2. Build the benchmark harness before optimizing anything.
3. Boot a minimal Linux VM through Virtualization.framework.
4. Install containerd/BuildKit in the guest and forward the Docker socket.
5. Implement ConjetFS one-way sync with dependency/build folders kept VM-native.
6. Run the first real comparison: ConjetFS MVP vs Colima tuned VZ + VirtioFS vs OrbStack on `pnpm install`, `npm install`, `composer install`, and cold Compose startup.

[^apple-vz]: https://developer.apple.com/documentation/virtualization
[^apple-shared]: https://developer.apple.com/documentation/virtualization/shared-directories
[^apple-rosetta]: https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms-with-rosetta
[^colima-config]: https://colima.run/docs/configuration/
[^lima-vmtype]: https://lima-vm.io/docs/config/vmtype/
[^lima-mount]: https://lima-vm.io/docs/config/mount/
[^orbstack-architecture]: https://docs.orbstack.dev/architecture
[^orbstack-files]: https://docs.orbstack.dev/docker/file-sharing
[^orbstack-network]: https://docs.orbstack.dev/docker/network
[^docker-settings]: https://docs.docker.com/desktop/settings-and-maintenance/settings/
[^docker-sync]: https://docs.docker.com/desktop/features/synchronized-file-sharing/
[^apple-containerization]: https://github.com/apple/containerization
[^buildkit]: https://docs.docker.com/build/buildkit/
[^containerd-remote]: https://containerd.io/docs/2.1/remote-snapshotter/

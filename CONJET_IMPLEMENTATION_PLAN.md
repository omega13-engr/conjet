# CONJET_IMPLEMENTATION_PLAN.md

This plan is a current-state implementation plan and next-generation feature
roadmap for Conjet. It is intentionally benchmark-driven: a feature or
performance claim is not considered supported until the matching harness has
measured it without regressing Conjet's existing speed, efficiency,
reliability, or security gates.

Claim levels used in this document:

- `PROVEN`: implemented and validated by a repeatable gate with sufficient
  samples and visible caveats.
- `PARTIAL`: implemented for a constrained path, but not complete across every
  mode or workload.
- `PLANNED`: feasible and designed, but not implemented or not yet gated.
- `EXPERIMENTAL`: possible, but high-risk or dependent on kernel/runtime
  capability work.
- `NOT SUPPORTED YET`: not currently implemented and must not be claimed.

## 1. Current Status Summary

Conjet has moved beyond the initial wishlist stage. The current runtime has a
Swift CLI and daemon, a profile-scoped state root, Apple
Virtualization.framework VM lifecycle, Conjet Core image import, Docker socket
forwarding over VSOCK, ConjetFS project sync, SmartBind/native-volume topology
optimization, energy modes, benchmark tooling, and secure-local ConjetNet
TCP/UDP port publishing.

Current proven or partially proven evidence:

- Warm local development gates have strong evidence for the measured workload
  matrix where ConjetFS, SmartBind, and native Linux storage are used correctly.
- Cold base-prepulled and no-cache gates have strong current evidence from the
  latest benchmark iterations, but reports must continue to name the exact
  phase and compared contexts.
- Topology gates strongly support the design choice of keeping dependency,
  cache, and build churn on Linux-native storage.
- Polyglot gates show the topology strategy generalizes beyond a single
  ecosystem, but each language claim must name the measured row and sample
  count.
- ConjetNet has working secure-local TCP/UDP forwarding, visible port state,
  capability reporting, repair commands, native `conjet-netd-c` guest helper
  support, persistent binary UDP mode, and persistent binary TCP pool evidence.
- Networking is competitive in several measured rows. This is not a blanket
  networking superiority claim; port publication and some tail-latency rows
  remain improvement areas.
- Energy measurement exists, including active sampling paths, but energy
  superiority is not proven until privileged `powermetrics` runs pass the
  energy gate with enough samples.

Current limitations:

- Kubernetes is not supported in this generation.
- Rootless mode, eBPF support, VPN-aware networking, SSH agent forwarding, and
  explicit isolated-machine mode are not yet supported features.
- Low-memory profile policy, memory policy reporting, lazy helper policy fields,
  and first-container memory gate measurement are implemented and proven for the
  current balanced profile by `memory-gate --first-container`. This is not a
  broad claim that every workload uses less memory by default.
- IPv6 loopback TCP and UDP publication are implemented and proven by
  `ipv6-gate`; broader guest, LAN, wildcard, and global IPv6 exposure behavior
  remains planned.
- Clock drift can be probed and explicitly repaired through
  `conjet doctor clock --repair`, daemon `clock-repair`, and
  `conjet-bench clock-gate --repair`. Daemon wake-gap repair is implemented;
  physical macOS sleep/wake coverage still needs a dedicated wake/resume gate.
- SSH key lifecycle, guest `sshd` hardening, disabled mode, and `conjet ssh`
  over a local ProxyCommand transport are implemented and proven by
  `ssh-gate --require-endpoint --check-disabled-mode`; a dedicated localhost
  TCP SSH listener is not claimed yet.
- Conjet should not claim broad industry-grade behavior for every networking
  mode until VPN, IPv6, LAN, docker-strict, and split-tunnel cases have their
  own gates.

## 2. Completed Foundations

### ConjetFS / SmartBind

- ConjetFS syncs host-authoritative project files into a VM-native Docker
  volume mounted at `/workspace`.
- Dependency and build churn, such as `node_modules`, Cargo `target`, package
  caches, and generated state, stays on Linux-native storage by default.
- `conjet sync push`, `conjet sync watch`, `conjet sync repair`, and
  `conjet sync export` provide the current project workflow.
- SmartBind and topology-aware benchmark rows separate strict host bind mounts
  from native-overlay or ConjetFS paths so reports do not mislabel results.

### Warm/Cold/No-Cache Gates

- `conjet-bench gate` validates raw benchmark JSON instead of Markdown
  summaries.
- `warm`, `cold-base-prepulled`, and `no-cache` phases are distinct and must
  remain distinct in release reports.
- Existing gates prevent under-evidenced global speed claims.

### Topology Gate

- The topology gate validates the core Conjet thesis: host-visible source files
  should be read-mostly while write-heavy dependency/build paths should stay in
  native Linux storage.
- This is a major Conjet advantage and must remain the baseline for future
  feature work.

### Polyglot Gate

- The polyglot gate covers multiple ecosystems and records topology metadata.
- Strong publication coverage should include JS, Python, JVM, .NET, Go, Rust,
  and C/C++ where local toolchain images are available.

### ConjetNet TCP/UDP

- ConjetNet publishes Docker ports to macOS localhost by default under
  `secure-local`.
- TCP and UDP support are capability-reported by the guest bridge.
- `docker-strict` and `lan-allowlist` are policy modes, but LAN exposure must
  remain explicit.

### conjet-netd-c Native Networking

- Newer Conjet Core images include the compiled `conjet-netd` helper.
- Benchmark-visible fields identify proxy engine, bridge engine, TCP mode, UDP
  mode, binary frame use, and Python fallback state.
- Persistent binary UDP and persistent binary TCP pool paths exist; TCP stream
  multiplexing is not yet implemented.

### Benchmark Harness

- `benchmarks/` is a standalone Swift package.
- Existing commands include `run`, `gate`, `energy-gate`, `network-gate`, and
  `network-segments`.
- Benchmark reports capture machine profile, topology, phase, sample count,
  failures, raw JSON, and Markdown summaries.

### Power/Energy Harness Status

- Power and active energy sampling paths exist.
- Missing or unprivileged `powermetrics` data is not proof.
- Energy superiority remains unproven until `energy-gate --require-power`
  passes with sufficient samples across Conjet and required baselines.

## 3. Claim Matrix

| Claim | Status | Evidence | Caveat |
| --- | --- | --- | --- |
| Docker-compatible local runtime path | PARTIAL | `conjet run`, `conjet compose up`, Docker socket bridge, profile contexts | Compatibility is practical for local workflows, not a full Docker Desktop replacement claim. |
| ConjetFS/SmartBind topology advantage | PROVEN | Warm/cold/no-cache/topology gates and ConjetFS benchmark rows | Claim only for measured topology rows and contexts. |
| Strong warm benchmark performance | PROVEN | Warm gate evidence with raw JSON reports | Do not generalize to unmeasured workloads. |
| Strong cold base-prepulled/no-cache performance | PROVEN | Cold and no-cache gates in current benchmark iterations | Must keep phase labels visible. |
| Polyglot topology generalization | PARTIAL | Polyglot gate coverage | Each ecosystem needs its own row-level claim. |
| Secure-local TCP publishing | PROVEN | Network gate and ConjetNet status/capability reporting | Default localhost behavior only. |
| Secure-local UDP publishing | PARTIAL | UDP echo rows with `conjet-netd-c` and capability gates | Requires active guest image support. |
| Networking superiority over incumbents | PARTIAL | Competitive measured rows | Not a global claim; port publication and tail latency remain targets. |
| Low idle energy or active energy superiority | PLANNED | Energy harness exists | Not proven until privileged power gate passes. |
| Low initial memory mode | PROVEN | Memory profile config/policy, lazy helper policy fields, status reporting, and `memory-gate --first-container` E2E report | Proven for scoped policy/gate behavior; no broad low-memory superiority claim. |
| Isolated machines | PLANNED | Profiles provide separate state roots | VM-per-project isolation is not implemented or tested. |
| VPN-friendly networking | PLANNED | ConjetNet policy engine exists | No route/DNS watcher or VPN gate yet. |
| IPv6 loopback TCP/UDP publication | PROVEN | `ipv6-gate` E2E passed for `http://[::1]:PORT/` and UDP echo on `[::1]:PORT` | Only scoped loopback is proven; LAN/global/wildcard IPv6 remains unclaimed. |
| Accurate clock probe/repair | PROVEN | `conjet doctor clock --repair`, daemon `clock-repair`, wake-gap repair path, and `clock-gate --repair` with `<100 ms` gate | Physical macOS sleep/wake E2E remains a future gate row. |
| Guest Linux eBPF | EXPERIMENTAL | Feasible with kernel config and privileged guest policy | Must not imply macOS kernel eBPF. |
| SSH into Conjet machines | PROVEN | `conjet ssh`, `conjet ssh-key rotate`, guest hardening, disabled mode, and `ssh-gate --require-endpoint --check-disabled-mode` over local ProxyCommand | Dedicated localhost TCP listener is not claimed. |
| SSH agent forwarding | PLANNED | Secure-local channels can support opt-in forwarding | High secret-exposure risk; disabled by default. |
| Rootless mode | EXPERIMENTAL | User/profile separation exists | Rootless meanings must be scoped and tested separately. |

## 4. Next Feature Initiatives

### 4.1 Low Initial Memory Usage

Status: `PROVEN`

Goal:

Reduce cold-start and idle memory footprint without regressing time to first
container, warm/cold benchmark gates, network reliability, or ConjetFS sync
latency.

Architecture:

- Add explicit profile modes: `performance`, `balanced`, and `eco`.
- Keep the current performance-oriented path as the control group.
- Introduce a low-memory boot profile with a smaller default guest memory
  target, delayed helper startup, and measured idle reclaim.
- Start guest services lazily where possible:
  - delay BuildKit until the first build;
  - delay containerd-adjacent maintenance tasks until Docker API demand;
  - avoid eager host watchers until a project is attached or watched;
  - avoid network helper startup until Docker published ports exist;
  - reclaim idle network helper processes after a quiet interval.
- Keep ConjetFS manifests and daemon status snapshots lightweight and
  event-driven; avoid periodic scans on the hot path.

Performance Risk:

- Too little guest memory can increase page cache misses, image unpack time,
  BuildKit latency, and first-container latency.
- Lazy service start can shift cost into the first user command.
- Aggressive helper reclaim can regress port publication latency and Docker API
  burst handling.
- Mitigation: gate each memory profile against existing warm, cold-base-prepulled,
  no-cache, topology, and network gates before changing defaults.

Security Risk:

- Low-memory mode should not weaken isolation, skip capability checks, or
  bypass secure-local policy.
- Reclaimed helpers must close sockets and remove stale listeners deterministically.

Implementation Tasks:

- Implemented: memory profile configuration in profile state and `conjet start`
  via `--memory-profile` and `CONJET_MEMORY_PROFILE`.
- Implemented: `ConjetMemoryPolicy` separates memory/lazy-helper policy from
  CPU/event cadence.
- Implemented: profile-aware default memory selection, including scoped eco
  default reduction when memory is not explicitly configured.
- Implemented: daemon status reports the active memory policy.
- Implemented: host and guest process RSS accounting in `memory-gate`.
- Implemented: `time_to_first_container` measurement via
  `memory-gate --first-container`.
- Implemented: lazy network-helper policy and idle helper reclaim policy are
  surfaced as measurable policy fields.
- Later: add deeper guest service lazy-start hooks for BuildKit and containerd
  maintenance where compatible with Docker behavior.
- Later: add helper idle reaper structured logs and per-helper state.

Validation Harness:

- Existing command: `conjet-bench memory-gate --first-container`.
- Metrics:
  - `initial_rss_mb`
  - `vm_memory_mb`
  - `conjetd_rss_mb`
  - `guest_agent_rss_mb`
  - `containerd_rss_mb`
  - `buildkitd_rss_mb`
  - `network_helper_rss_mb`
  - `time_to_first_container`
  - `idle_wakeups_per_sec`
- Run memory-gate in `performance`, `balanced`, and `eco`.
- Re-run existing warm, cold-base-prepulled, no-cache, topology, and network
  gates after any default memory change.

Release Gate:

- `memory-gate --first-container` passes and records RSS/process metrics.
- Active daemon status reports the selected memory policy.
- Existing warm/cold/network gates continue to pass before changing defaults.
- Startup time and time to first container remain competitive against the
  release baseline.
- Do not claim broad memory superiority until per-profile budgets are approved.

### 4.2 Isolated Machines / High-Security Sandbox Mode

Status: `PLANNED`

Goal:

Provide stronger project or container-group isolation for untrusted images and
sensitive work while preserving the shared fast VM path for normal development.

Architecture:

- Keep `dev-cell` mode as the default:
  - one shared VM optimized for fast Docker/Compose development;
  - shared image cache;
  - shared ConjetFS/SmartBind workflow;
  - secure-local port publishing.
- Add `isolated-machine` mode:
  - one VM or isolated VM profile per project/container group;
  - separate Docker socket and Docker context;
  - separate network namespace/policy state;
  - separate volume store and image/cache store where required;
  - no shared ConjetFS state unless explicitly mounted;
  - destroy operation removes VM disk, Docker state, volumes, sockets, and
    network policy state.
- Treat VM-per-container as a future optional mode, not the default roadmap
  target.

Performance Risk:

- VM-per-project increases cold start, memory footprint, image pull/cache
  duplication, and disk use.
- Compose workflows may be slower when image cache is not shared.
- Mitigation: keep dev-cell as default and make isolated-machine explicitly
  opt-in with measured overhead.

Security Risk:

- Main threats are cross-project Docker socket access, volume leakage, port
  policy confusion, shared ConjetFS state, and stale state after destroy.
- Controls: per-profile sockets with strict permissions, per-machine state
  roots, scoped port policy, explicit host mounts, and destroy verification.

Implementation Tasks:

- Add machine identity and isolation mode to profile/project config.
- Create per-machine Docker socket paths and contexts.
- Create per-machine VM disks, volume roots, bootstrap shares, and logs.
- Scope ConjetNet port registry and policies by machine.
- Add `conjet machine create`, `conjet machine list`,
  `conjet machine destroy`, and project attachment to isolated machines.
- Document isolation semantics and what is still shared by macOS user account.

Validation Harness:

- Add `conjet-bench isolation-gate`.
- Tests:
  - Project A cannot access Project B volumes.
  - Project A cannot access Project B Docker socket.
  - Network isolation works.
  - Port policies remain scoped.
  - Destroying isolated machine removes state.
  - Explicit shared mounts are the only allowed cross-machine file path.

Release Gate:

- Isolation semantics are documented.
- Escape paths are tested.
- Performance overhead is measured and published.
- No feature copy claims "fully secure"; call it isolated-machine mode with
  documented boundaries.

### 4.3 VPN-Friendly Networking

Status: `PLANNED`

Goal:

Make Conjet networking behave predictably when macOS DNS resolvers and routes
change under split-tunnel or full-tunnel VPNs, while preserving secure-local
published ports and avoiding accidental traffic leaks.

Architecture:

- Add a ConjetNet VPN watcher:
  - observe macOS route and DNS resolver changes;
  - detect VPN interface changes;
  - update guest DNS configuration;
  - update forwarding policy;
  - preserve secure-local published ports;
  - expose current DNS/route source in `conjet network status --json`.
- Default behavior remains secure-local: Docker-published ports stay on
  localhost and are not exposed to LAN/VPN interfaces unless policy explicitly
  allows it.
- Add policy modes for VPN-required traffic where Conjet refuses guest egress
  or DNS fallback if VPN resolvers/routes are missing.

Performance Risk:

- Route watchers and DNS updates can add wakeups if implemented by polling.
- Resolver churn can briefly interrupt guest DNS.
- Mitigation: use event-driven macOS notifications where possible, debounce
  updates, and avoid restarting network helpers unless policy truly changes.

Security Risk:

- Full-tunnel VPN policy must not leak traffic through pre-VPN default routes.
- Split-tunnel DNS must not fall back to public resolvers for VPN-only domains
  when policy forbids leakage.
- LAN exposure must remain opt-in.

Implementation Tasks:

- Add macOS resolver/route observer.
- Add guest DNS update path with rollback.
- Add VPN policy configuration and status reporting.
- Add network repair path for stale DNS/route state.
- Document split-tunnel, full-tunnel, and unsupported VPN cases.

Validation Harness:

- Add `conjet-bench vpn-gate`.
- Tests:
  - DNS resolver changes propagate to guest.
  - Container can resolve VPN-only domains when VPN is active.
  - Published localhost ports still work.
  - No accidental LAN exposure under secure-local.
  - VPN-required policy fails closed when VPN disappears.
- If a real VPN cannot be automated in CI, add a manual protocol with:
  - VPN product/name;
  - split/full tunnel mode;
  - before/after `scutil --dns`;
  - route table sample;
  - guest resolver sample;
  - leak-test result.

Release Gate:

- VPN behavior is documented.
- DNS/route update path works under the gate or manual protocol.
- Secure-local mode has no LAN or non-VPN leak in tested policies.

### 4.4 IPv6 Support

Status: `PROVEN`

Goal:

Support IPv6 loopback for published ports and guest/container networking where
capabilities exist, without regressing IPv4 behavior or accidentally widening
LAN/global exposure.

Architecture:

- Keep IPv4 stable and treat it as the compatibility baseline.
- Add explicit IPv6 listener support for `::1` in secure-local mode.
- Add IPv6 capability reporting to ConjetNet status.
- Add docker-strict IPv6 semantics only when enabled and clearly reported.
- Keep LAN/global IPv6 exposure off by default; require explicit policy.
- Extend DNS handling to preserve A and AAAA behavior without forcing IPv6 on
  projects that do not need it.

Performance Risk:

- Dual-stack listeners can add code paths and tail-latency variance.
- Misconfigured IPv6 fallback can slow connection setup.
- Mitigation: benchmark IPv4 and IPv6 rows separately and require IPv4
  non-regression.

Security Risk:

- IPv6 wildcard binds such as `[::]` can expose services even when IPv4 policy
  appears local.
- Controls: secure-local maps published ports to `127.0.0.1` and `::1` only;
  docker-strict and global exposure require explicit policy and diagnostics.

Implementation Tasks:

- Implemented: IPv6 bind/listener support in host port forwarders, including
  `IPV6_V6ONLY`.
- Implemented: scoped TCP loopback gate for `[::1]`.
- Implemented: Python and native guest bridge parsing for IPv6 loopback UDP
  proxy targets.
- Implemented: host UDP listener coalescing so concurrent Docker target events
  cannot double-bind the same IPv6 UDP port.
- Implemented: TCP and UDP `::1` rows in `ipv6-gate`.
- Later: add IPv6 policy fields and diagnostics for LAN/global/wildcard IPv6.
- Later: update docs to distinguish loopback IPv6 from LAN/global IPv6.

Validation Harness:

- Existing command: `conjet-bench ipv6-gate`.
- Tests:
  - `::1` published TCP port works.
  - `::1` published UDP port works if UDP/IPv6 is supported.
  - IPv6 policy respects secure-local.
  - Docker-strict `[::]` behavior is explicit.
  - IPv4 behavior does not regress.

Release Gate:

- IPv6 loopback TCP and UDP support are proven by `ipv6-gate`.
- Optional LAN/global IPv6 exposure has explicit policy, tests, and docs.
- No IPv4 gate regression.

### 4.5 Accurate Clock

Status: `PROVEN`

Goal:

Keep guest time close enough to host time for TLS certificates, databases,
tests, build systems, package managers, and reproducible benchmark timing,
especially after VM start, host sleep, and resume.

Architecture:

- Add a Conjet Clock Agent:
  - check host/guest delta;
  - resync after VM start;
  - resync after macOS wake;
  - expose status in `conjet doctor`;
  - fail clearly when guest time cannot be repaired.
- Prefer host-driven correction through guest agent or existing guest time sync
  service. Evaluate NTP, chrony, and systemd-timesyncd only as guest-image
  options, not as hidden dependencies on public network access.
- Keep `conjet doctor clock` as the user-facing diagnostic command.

Performance Risk:

- Clock checks should not add frequent wakeups.
- Time repair should not block common CLI status calls.
- Mitigation: check on lifecycle events and explicit doctor command, with a
  low-frequency background check only when VM is running.

Security Risk:

- Incorrect time can break certificate validation and package integrity.
- Time sync must not require exposing guest management ports.
- Host-to-guest clock correction should be authenticated through Conjet's
  existing control plane.

Implementation Tasks:

- Implemented: guest time query and explicit repair command.
- Implemented: daemon lifecycle repair after VM start.
- Implemented: daemon wake-gap repair loop for host sleep/resume-like gaps.
- Implemented: `conjet doctor clock` and repair-capable JSON status fields.
- Implemented: daemon `clock-repair` protocol command.
- Later: add explicit macOS sleep/wake notification hook and physical
  sleep/resume gate row.
- Later: add configurable drift thresholds.

Validation Harness:

- Existing command: `conjet-bench clock-gate --repair`.
- Metrics:
  - `host_guest_clock_delta_ms`
  - `delta_after_sleep_ms`
  - `delta_after_resume_ms`
  - `resync_latency_ms`
- Include start, restart, and simulated drift cases.
- Later: add physical macOS sleep/wake E2E row.

Release Gate:

- Clock drift remains below threshold, for example `<100 ms` after start and
  after explicit repair.
- `conjet doctor clock` reports drift and repair state clearly.
- Clock repair does not regress startup or benchmark gates.
- Do not claim physical sleep/wake coverage until the wake/resume row passes.

### 4.6 eBPF Support

Status: `EXPERIMENTAL`

Goal:

Provide scoped guest-Linux eBPF capability for developer debugging,
observability, network tracing, low-overhead packet metrics, and future
ConjetNet acceleration experiments. This is guest Linux eBPF only; it is not
macOS kernel eBPF.

Architecture:

- Add guest kernel capability reporting for:
  - `BPF`
  - `BPF_SYSCALL`
  - `BPF_JIT`
  - `BPF_EVENTS`
  - `CGROUP_BPF`
  - `XDP` only if explicitly targeted.
- Include `bpftool` in eBPF-capable guest images or install it through an
  optional package layer.
- Keep eBPF disabled for untrusted normal containers by default.
- Require privileged container mode or a narrowly scoped Conjet debug profile
  for loading programs.
- Report rootless limitations explicitly.

Performance Risk:

- BPF JIT and tracing can add overhead or perturb benchmark results.
- XDP/packet hooks can change network behavior.
- Mitigation: eBPF debug mode is opt-in and excluded from normal performance
  claims unless measured separately.

Security Risk:

- eBPF can expand kernel attack surface, observe sensitive data, or enable
  privileged container behavior.
- Controls: disabled by default for untrusted containers, capability-reported,
  privileged/debug profile required, and no silent capability escalation.

Implementation Tasks:

- Add kernel config audit to guest image build.
- Add `bpftool` probe command through `conjet doctor` or `conjet ebpf status`.
- Add debug profile policy for eBPF-enabled containers.
- Add docs distinguishing guest eBPF from macOS eBPF.
- Add tests for denied default container behavior.

Validation Harness:

- Add `conjet-bench ebpf-gate`.
- Tests:
  - `bpftool feature probe`.
  - Load a harmless BPF program.
  - Attach a basic tracepoint or cgroup program if safe.
  - Verify eBPF is disabled by default for untrusted containers.
  - Verify rootless limitations are reported.

Release Gate:

- eBPF support is capability-reported.
- Security mode is documented.
- Normal containers do not receive default escalation.
- Any performance claim is scoped to measured eBPF rows only.

### 4.7 SSH Support

Status: `PROVEN`

Goal:

Provide a reliable, secure-local SSH entry point for users who need direct
shell access to Conjet machines or project profiles.

Architecture:

- Implemented: Conjet-managed SSH over local OpenSSH `ProxyCommand` that runs
  guest `sshd -i` through the existing local Docker/nsenter control path.
- Implemented: no LAN listener by default.
- Implemented: profile-scoped Ed25519 keys with strict permissions.
- Implemented: key rotation.
- Implemented: disabled mode with config persistence and negative command test.
- Planned: dedicated localhost TCP listener and `conjet doctor` integration.
- Commands:
  - `conjet ssh`
  - `conjet ssh --profile work`
  - `conjet ssh project-name`
  - `conjet ssh-key rotate`
  - `conjet ssh status`

Performance Risk:

- Starting `sshd` eagerly adds guest memory and idle wakeups.
- Host forwarding adds one more listener to reconcile.
- Mitigation: lazy-start SSH or keep it disabled until first use; measure with
  memory-gate and network-gate.

Security Risk:

- SSH can expose a direct guest management path.
- Controls: localhost-only by default, profile-scoped keys, no password login,
  correct file permissions, explicit disabled mode, and no LAN binding unless a
  future policy explicitly allows it.

Implementation Tasks:

- Implemented: guest SSH package/config in cloud-init and lazy installer for
  existing VMs.
- Implemented: host key and user key lifecycle.
- Implemented: `conjet ssh`, `conjet ssh-key rotate`, and `conjet ssh status`.
- Implemented: SSH self-repair starts guest `sshd`, creates `/run/sshd`,
  validates config, and installs the profile-scoped authorized key.
- Planned: localhost-only TCP forward registration.
- Add doctor checks for key permissions and endpoint status.

Validation Harness:

- Existing command: `conjet-bench ssh-gate --require-endpoint --check-disabled-mode`.
- Tests:
  - SSH connects to guest.
  - SSH is localhost-only by default.
  - SSH key is profile-scoped.
  - SSH disabled mode works.
  - SSH survives VM restart.
  - Key permissions are correct.

Release Gate:

- SSH command works through the local ProxyCommand transport.
- No LAN exposure by default.
- Key lifecycle and permissions pass tests.
- Memory and network gates do not regress.

### 4.8 SSH Agent Forwarding

Status: `PLANNED`

Goal:

Allow opt-in use of the user's SSH agent for workflows such as cloning private
repositories or fetching from private Git remotes inside the guest or selected
containers.

Architecture:

- Disabled by default.
- Profile/project scoped.
- Forward agent over a secure local channel.
- Never expose the agent to all containers by default.
- Prefer per-command forwarding:
  - `conjet run --ssh-agent ...`
  - `conjet compose up --ssh-agent`
- Add status command:
  - `conjet ssh-agent status`
- Remove forwarded sockets when the command or project session ends.

Performance Risk:

- Minimal steady-state cost if disabled by default.
- Per-command forwarding adds setup/teardown latency.
- Mitigation: keep default disabled and measure command startup delta in
  ssh-gate.

Security Risk:

- Main risks are agent socket exposure, containers stealing signing ability,
  cross-project access, and long-lived forwarded sockets.
- Controls: explicit opt-in, per-command scope, project scoping,
  short-lived sockets, strict permissions, and isolation tests.

Implementation Tasks:

- Add host SSH_AUTH_SOCK discovery and validation.
- Add scoped agent forwarding channel.
- Mount/inject agent socket only into requested guest/project/container scope.
- Add teardown and stale socket cleanup.
- Add docs for risk model and safe usage.

Validation Harness:

- Extend `ssh-gate` or add `ssh-agent-gate`.
- Tests:
  - Agent forwarding disabled by default.
  - Agent enabled only for requested container/project.
  - Socket removed after command.
  - Unrelated containers cannot access agent.
  - Private Git smoke test works when an agent with access is present.

Release Gate:

- Explicit opt-in only.
- Isolation tests pass.
- Risk model is documented.
- No cross-project agent access.

### 4.9 Rootless Mode

Status: `EXPERIMENTAL`

Goal:

Reduce privilege and blast radius where feasible, while avoiding a vague
"rootless" claim. Rootless has multiple meanings and each must be implemented,
tested, and documented separately.

Architecture:

- Define four separate modes:
  - Host-rootless: Conjet daemon does not require root on macOS.
  - Guest-rootless: containers run rootless inside the Linux guest.
  - Docker-rootless: dockerd/containerd runs rootless.
  - Userns-remap: root inside a container maps to a non-root guest UID.
- Current Conjet is closest to host-rootless because the daemon uses a
  user-owned socket and no privileged helper by default, but this still needs a
  formal gate.
- Start with userns-remap or selected guest-rootless container workflows before
  attempting Docker-rootless as a default.
- Treat eBPF, low port binding, overlayfs, fuse-overlayfs, networking, and
  volume ownership as explicit compatibility dimensions.

Performance Risk:

- fuse-overlayfs can be slower than overlayfs.
- Rootless networking can add proxy overhead and limit low-port behavior.
- UID/GID remapping can complicate ConjetFS ownership and bind semantics.
- Mitigation: rootless-gate must compare startup, build, filesystem,
  networking, and Compose rows before any default change.

Security Risk:

- Rootless can improve containment but can also create false confidence if
  Docker socket, host mounts, or agent sockets remain reachable.
- Controls: precise mode naming, no blanket claim, documented limitations, and
  tests for write restrictions and namespace mapping.

Implementation Tasks:

- Add rootless mode config with explicit mode names.
- Add guest user namespace and subordinate ID setup.
- Evaluate userns-remap with current Docker path.
- Evaluate guest-rootless container run support.
- Evaluate Docker-rootless separately with Compose compatibility tests.
- Add diagnostics for unsupported eBPF, low ports, overlayfs, and networking.

Validation Harness:

- Add `conjet-bench rootless-gate`.
- Tests:
  - Rootless container cannot write host-owned restricted paths.
  - User namespace mapping works.
  - Common Docker/Compose workflows still work.
  - Performance impact is measured.
  - Networking limitations are documented.
  - eBPF limitations are reported.

Release Gate:

- Rootless mode is explicitly scoped.
- No silent compatibility regressions.
- Performance and feature limitations are documented.
- Existing speed gates remain protected for the default non-rootless path.

## 5. Harness Engineering Roadmap

### memory-gate

- Existing command: `conjet-bench memory-gate --first-container`.
- Implemented: process and guest RSS sampling for current helper/runtime
  processes.
- Implemented: first-container latency measurement.
- Implemented: policy fields for idle wakeup budget and helper reclaim.
- Later: add actual idle wakeup sampling.
- Compare profile modes and assert no existing speed gate regression.

### isolation-gate

- Create two isolated projects or machines.
- Verify socket, volume, network, port-policy, and destroy isolation.
- Record overhead versus default dev-cell mode.

### vpn-gate

- Add route/DNS fixture support where possible.
- Add manual protocol for real VPN products when automation is unavailable.
- Verify no secure-local LAN exposure.

### ipv6-gate

- Implemented: TCP and UDP `::1` publication rows.
- Add IPv4 non-regression rows.
- Add docker-strict IPv6 policy rows.

### clock-gate

- Existing command: `conjet-bench clock-gate --repair`.
- Expand host/guest time delta sampler coverage.
- Implemented: explicit drift repair gate.
- Add wake/resume row for physical macOS sleep coverage.
- Add deeper `conjet doctor clock` assertions.

### ebpf-gate

- Add kernel config probe.
- Add `bpftool feature probe`.
- Add harmless program load/attach tests.
- Add denied-by-default tests for normal containers.

### ssh-gate

- Existing command:
  `conjet-bench ssh-gate --require-endpoint --check-disabled-mode`.
- Implemented: key existence, guest authorized key, guest `sshd`, localhost-only
  endpoint, endpoint reachability, and disabled-mode tests.
- Later: add dedicated localhost TCP listener tests.
- Later: add restart persistence tests as a separate row.

### rootless-gate

- Add mode-specific rootless tests rather than a single blanket verdict.
- Measure filesystem, networking, Compose, and build impacts.
- Record unsupported features explicitly.

### energy-gate Improvement

- Make privileged `powermetrics` setup clearer.
- Keep missing power data as skipped or failed according to `--require-power`.
- Add memory and helper wakeup attribution where possible.
- Do not allow energy superiority claims from wall-time-only evidence.

## 6. Release Gates

Required before a feature is called supported:

- The feature has a documented status level and scope.
- The implementation has unit tests for policy/config behavior.
- The implementation has integration tests for the user-facing command path.
- The matching `conjet-bench <feature>-gate` exists or a documented manual
  protocol exists when automation is not feasible.
- Existing warm, cold-base-prepulled, no-cache, topology, and network gates are
  rerun when the feature can affect speed or networking.
- Security-sensitive features have negative tests proving default-deny behavior.
- Release notes state caveats and unsupported modes.

Required before a performance claim is allowed:

- Raw JSON report exists under `benchmarks/reports/`.
- Markdown summary names contexts, sample count, topology, phase, failures, and
  caveats.
- The claim uses the narrow measured workload name.
- Required baselines are present.
- P50 and P95 meet the gate.
- Failed or skipped rows are published, not hidden.
- Energy claims require privileged power data with `--require-power`.

## 7. Non-Goals

- No Kubernetes in this generation unless explicitly planned in a separate
  roadmap.
- No energy superiority claim until privileged energy gates prove it.
- No rootless blanket claim until host-rootless, guest-rootless,
  Docker-rootless, and userns-remap are scoped separately.
- No LAN exposure by default.
- No claim that Conjet is fully industry-grade for every networking mode.
- No broad claim that eBPF, IPv6, SSH, SSH agent forwarding, rootless mode,
  VPN-aware networking, or isolated-machine mode is supported beyond the
  specific implementation scope proven by gates.
- No VM-per-container default until VM-per-project isolation is implemented and
  measured.

## 8. Engineering Priority Order

1. Memory gate / low initial memory
2. Clock + doctor reliability
3. SSH
4. IPv6 loopback
5. VPN-friendly DNS/route sync
6. Isolated machines
7. SSH agent forwarding
8. eBPF support
9. Rootless

The ordering protects Conjet's speed foundation. Memory and clock work improve
baseline runtime reliability without changing developer workflow semantics.
SSH and IPv6 are bounded user-facing features. VPN and isolated machines expand
networking and security scope and therefore need stronger gates. SSH agent
forwarding, eBPF, and rootless mode carry higher security or compatibility risk
and should remain opt-in until their harnesses are mature.

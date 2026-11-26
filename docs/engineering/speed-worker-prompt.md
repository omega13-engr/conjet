# Active scope override: native engine

The user explicitly authorizes replacing dockerd/containerd/runc. Read and
execute `docs/engineering/native-engine-v2-plan.md` and SPEED-057–065 in the
task board first. These supersede the retained-engine mission below.
Reuse current Conjet native research; retain full Core dynamic memory.
Begin with SPEED-057 immediately, then memory integration and native benchmarks.
Continue implementation and verified incremental pushes without stopping at
the historical SPEED-051/055 retained-engine blockers. Do not claim they were
fixed. Split newly discovered missing capabilities into narrow tasks and
execute them. No hidden runtime fallback or unverified superiority claims.
The isolation, validation, cleanup and publication gates below still apply.

---

# Retained Docker speed worker: end-to-end instructions

Work in `/Users/sly/Workspace/Personal/conjet` on `enhancement/speed-up`.
Requested model: GPT-6.2 Sol, High reasoning. If the launch interface does
not expose reasoning effort, do not claim that High has been configured.

## Mission

Execute SPEED-051, SPEED-050, SPEED-052, SPEED-053, SPEED-054, then SPEED-055
from the task board. Complete the feasible implementation, tests, release
builds, experiments, documentation and incremental pushes in this session.
Continue between increments without asking for routine approval or ending
merely because one task passed. Do not create background persistence or an
unattended retry loop. A necessary external blocker must be reported honestly.

## Read before acting

Read AGENTS.md and applicable nested instructions, then:

- docs/engineering/retained-docker-latency-architecture.md
- docs/engineering/task-board.md
- docs/engineering/native-docker-speed-plan.md
- docs/engineering/docker-benchmark-plan.md
- docs/engineering/docker-benchmark-results.md
- docs/engineering/speedup-environment.md
- benchmarks/README.md

Verify the branch, working tree, upstream and current worker activity before
editing. The architecture was pushed at 59343f0; verify actual current HEAD.
Preserve unrelated graphify-out changes. Follow repository graphify rules.
Inspect actual code and raw evidence; documentation is not runtime proof.

## Non-negotiable scope

Retain dockerd, containerd, runc, BuildKit, Compose AND Conjet dynamic memory.
Do not restart the Rust Docker engine replacement or copy Kiri source.
Preserve pressure response, balloon growth/shrink, idle convergence, active
container data, scoped reclaim and backing-page ownership. No fixed-memory
benchmark shortcut, permanent prewarming, global cache dropping, reduced
security or relaxed resource limits. The 25 ms recovery tick stays enabled.

Production Conjet app, daemon, VM, containers, socket, Docker context and
Buildx selector must remain unchanged. Use private conjet-speedup endpoints,
explicit isolated configurations and session-scoped foreground services.
All scratch, builds, tests and evidence go under
/Volumes/ExternalSSD/dev_workspace/tmp. Do not use production Docker for
building the candidate. Stop owned processes and verify cleanup after each
boot and before ending. Remove disposable build/scratch trees; retain raw
benchmark evidence in the established evidence directory.

## Execute in order

1. SPEED-051: capture the actual failing process and cgroup for the four-PID
   exit-127 error. The runc diagnostic is a hypothesis, not attribution of
   the failed operation. Fix the confirmed cause at unchanged limits and
   add focused regression coverage. Do not raise the PID cap to pass.
2. SPEED-050: measure identical guest-local and forwarded API lifecycles,
   tagged relay spans, response completion and transport controls. Keep
   clock domains separate; quantify instrumentation effects. Capture reclaim
   activity, memory targets and CPU/PID resource events. If guest-local
   Docker already exceeds 5 ms, explicitly report the retained-engine floor
   and attribute its expensive stage before inventing another optimization.
3. SPEED-052: isolate routine stream-triggered reclaim scheduling. Test
   coalesced hints plus existing quiet dwell, generations and guest safety
   checks. Pressure handling and dynamic memory stay active. Accept only
   with improvement and passing memory gates; otherwise reject the candidate
   and preserve current behavior with evidence.
4. SPEED-053: add conditional response write readiness only if traces prove
   a WouldBlock stall. Preserve queue ownership, credit accounting, partial
   writes, EOF, cancellation and descriptor lifetime. If absent, record a
   negative investigation rather than adding speculative machinery.
5. SPEED-054: measure connection churn first. Implement sequential persistent
   ordinary HTTP only if beneficial, with per-request cgroup policy and full
   framing/streaming correctness. Do not change the frozen benchmark client
   to manufacture improvement. Keep separate diagnostic-client results.
6. SPEED-055: freeze accepted release artifacts and repeat five independent
   alternating boot pairs per API/CLI lane, 2,000 timed operations and ten
   warmups per engine/boot against official pinned Kiri. Keep normal dynamic
   memory enabled. Preserve failures, raw samples and cleanup evidence.

A rejected experiment may complete as a documented decision; never mark it
as an implemented speed improvement. If a hypothesis fails, use evidence to
select the next bounded investigation. Add a narrow task before implementing
an additional confirmed in-scope fix. Do not expand into a replacement engine.

## Validation and reporting

Run relevant formatting, lint, compile and focused tests, then broader
project-required checks before readiness. Use release builds for timings.
For memory-sensitive changes, prove active-data integrity, pressure response
during churn, idle convergence within existing policy, and balloon backing
ownership/release. Measure memory and CPU as well as latency. Keep test
execution outside benchmark timing windows.

Re-run affected bridge, exec/output, image, storage, build and Compose
compatibility fixtures. After lifecycle correctness gates, continue the
existing benchmark matrix tasks for candidate coverage. Preserve the recent
detailed report format: identities/hashes, per-boot p50/p95/p99, throughput,
API stages, paired ratios/95% intervals, failures, resources, cleanup,
coverage and explicit verdict. Historical results are not candidate results.

Keep existing CLI parity/API advantage criteria. Separately label the new
API parity assessment and below-5-ms median target. Do not substitute API
or native execution for CLI, cleanup acknowledgement for guest teardown, or
small A/B pilots for qualification. No promise of matching or beating Kiri.
Second-host, privileged energy and equivalent Kiri guest-teardown gaps remain
disclosed; continue independent work that does not need them.

## Delivery and stopping conditions

For each coherent verified increment: review the diff, update task status
and evidence, commit conventionally with the SPEED ID, push normally to
origin/enhancement/speed-up and verify the remote head. Keep one existing
PR #33; update its description to reflect retained Docker scope and current
results. No force push, unrelated files or direct main commits.

Continue until all feasible authorized tasks and candidate benchmark coverage
are completed or a concrete external blocker prevents further useful work.
Performance failure is a measured outcome, not permission to loosen gates.
Do not mark failed qualification DONE as a passing implementation. Report
which work is complete, rejected, under review or externally blocked.

Prepare review/release documentation when appropriate, but do not merge or
release unless independent review, CI and existing publication authorization
and signing/notarization gates are satisfied. Never fabricate approvals or
bypass missing credentials. No merge/release based on lifecycle results alone.

Final report must state exact pushed HEAD, task states, measured comparison,
memory results, test commands/results, production preservation, cleanup,
PR/CI status and any remaining blockers. Say explicitly whether Kiri parity
and the below-5-ms target passed or failed. Keep working through ordinary
implementation decisions rather than stopping with an offer to continue.

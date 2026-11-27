# Expanded Docker compatibility qualification

## Decision and current status

Keep the native engine and Core dynamic memory. Qualify Linux Docker behavior
on macOS using official Docker clients and a genuine Docker Engine reference.
Kiri remains a performance comparator and source of regression scenarios, not
the correctness oracle. Preserve the frozen 71-case manifest and its evidence.

The new [matrix](../../benchmarks/compatibility/matrix.json) contains 88 starting
contracts across 15 areas. Each maps to an executable method under
`benchmarks/compatibility/cases/`. All start UNTESTED and explicitly fail with
UNIMPLEMENTED. These are test contracts, not completed behavioral tests. Fast
inventory tests only verify mapping and strict result accounting. They cannot
establish product compatibility. No production release is authorized here.

This inventory is deliberately not called exhaustive. DC-SPEC must freeze the
official Engine API and Compose schema revisions and enumerate every operation,
field and option. Split grouped contracts into parametrized fixtures. Add new
rows for omissions rather than claiming coverage from a broad group name.

## Current build findings (2026-11-27)

The telemetry scanner stack-overflow fix is on PR #37 and passed installed-DMG
memory and sample Docker E2E checks. It does not establish this expanded matrix.
The `fix/docker-build-compatibility` increment decouples the BuildKit content
mirror from runnable-image staging. In the unchanged ARTEX reproducer, the
external Dockerfile frontend now resolves and its verified layer extracts.
Execution then fails with `unsupported live BuildKit OCI preset`.

The captured normalized frontend preset adds a read-only metadata bind at
`/run/config/buildkit/metadata`, uses only supplementary group 0 and requests
a network namespace. The existing guest mount contract handles only hosts,
resolver and tracing sources. Its build runtime also has one active execution
slot, no stdin operation in BuildOperation, retained output limited by the
workload output budget, and a 33-second wait deadline. Supporting the frontend
requires actual mount/namespace/group enforcement and duplex transport, not
adding another accepted policy hash. General parallel and long-running builds
need separately owned execution lifecycles and cancellation.

The new mirror is still anonymous Docker Hub read support, with 1 MiB metadata,
1 GiB per blob, 4 GiB cache and bounded descriptor/object counts. It does not
implement authenticated/private registries, pushes, other origins, general
container image pulls, external cache exporters or arbitrary Docker features.
The 88 contracts remain unimplemented qualification cases. Full Docker
compatibility and release readiness are **not established**.

Registry transport reference: [OCI Distribution pull semantics](https://github.com/opencontainers/distribution-spec/blob/main/spec.md#pull).

## Test layers

| Layer | Location | Purpose |
| --- | --- | --- |
| Unit | Existing Rust module tests and Swift Tests targets | Parsers, validation, resource accounting, error paths and state transitions |
| Harness unit | benchmarks/compatibility/test_inventory.py and future harness tests | Reject missing mappings, skipped results, unsafe endpoints and mismatched receipts |
| Differential integration | benchmarks/compatibility/cases/test_*.py | Same fixture against explicit reference Docker and Conjet endpoints; compare observable semantics |
| Ecosystem E2E | Testcontainers, Dev Containers, Compose and scanner fixtures | Verify real clients rather than only custom API calls |
| Installed-package E2E | Existing packaging launcher plus expanded cases | Exercise bundled CLI, daemon, VMM, guest and Core using exact package hashes |
| Soak/fault | Core, disk-full, cancellation and recovery cases | Bound failure, preserve state, verify growth/reclaim and stable long-running workloads |

Never substitute mocks for cgroup enforcement, capabilities, namespace
isolation, data persistence or actual network reachability. Add unit tests when
fixing the underlying defect, then rerun the real reproducer.

## Profiles and specification ownership

`single-host` is the proposed broad Linux-on-macOS release target. `swarm` and
`advanced` remain required for claims about those features; they are not counted
as passes when excluded. The `all` profile includes all three. A release must
state its scope explicitly. Windows containers are outside this platform; AMD64
emulation and GPUs require their own supported hardware and implementation.

Record official CLI, Compose, Buildx, reference Engine/API, kernel, architecture,
OS, image digests and configuration. Existing client pins are a baseline, not
proof of which Engine version a reference runs. Use reference Docker for Engine
semantics and a documented macOS platform reference for host file sharing and
host-gateway behavior. Do not assume Linux host-network semantics mean macOS
host-network semantics. Document intentional differences.

Compose-owned interpolation, merging and profiles need official-client tests.
Engine-owned limits, capabilities, mounts and network options need guest probes.
Swarm placement, reservations and rolling updates require scheduler tests;
accepting a deploy field is not proof of enforcement. Unsupported security or
resource settings must not silently report success. Pin reference behavior for
platform-dependent settings, including cgroup-v2 limitations.

## Isolation and harness contract

Use `/Volumes/ExternalSSD/dev_workspace/tmp` for all generated evidence, builds,
scratch homes and data. Require explicit candidate and reference endpoints and
private Docker configs. Never select a global context, mutate production Docker
settings, install startup jobs or operate on production containers. Observe
production process/endpoint fingerprints before and after runs.

Reuse project isolated launchers where suitable. Each test allocates uniquely
named resources, records ownership, and cleans in finally/cleanup handlers.
No global prune. Disk-full tests fill only a bounded disposable guest disk.
Fault injection targets only owned processes. Socket peer identity and runtime
artifact identity must pass before mutations. A deadline or interrupt must
clean owned resources and retain diagnostics. No persistent background services.
External networking/VPN and multi-host cases remain BLOCKED until their real
prerequisites are available; do not silently skip them into a green result.

## Evidence and pass rules

The future harness must emit case ID, manifest hash, candidate package and
binary hashes, reference versions, fixture digests, effective configuration,
timestamps, assertions, exit status, failure category and cleanup receipts.
Store artifacts outside the repository; retain original failed attempts.

Statuses: PASS, FAIL, UNTESTED, BLOCKED, UNSUPPORTED, NOT_APPLICABLE. Only PASS
counts toward implemented compatibility. Required skips, xfails, missing tests,
missing receipts or artifact mismatches block qualification. Exclusions require
an explicit reviewed scope change, not a test-run override. The present runner
rejects skips/xfails and incomplete counts, but is NOT yet an artifact-evidence
verifier. DC-RELEASE implements and validates that final gate.

Compare API schemas/status codes and behavior; normalize only nondeterministic
IDs/timestamps. Assert output, exit, ownership, disk contents and teardown.
Run positive, invalid-input and recovery variants. Use pairwise combinations
for general options, plus explicit high-risk interactions such as non-root +
bind + concurrent writes and memory pressure + build + database. Do not
attempt an unbounded Cartesian product.

Core retains responsibility for dynamic backing. Verify idle-to-burst recovery,
database health, guest pressure, CPU/IO, page faults and host footprint. Freeze
numerical soak budgets from measured reference/baseline before qualification;
do not choose tolerances after seeing failures. Require an eight-hour memory
soak and repeat fault cases on fresh sessions. Qualify additional supported
hardware/OS combinations before expanding platform claims.

## Sequential execution

1. DC-INFRA and DC-SPEC: isolated differential harness and complete pinned schema inventory.
2. Durable lifecycle and data integrity: persistence, restart policies, in-use volume protection and recovery.
3. Capabilities, namespaces and actual CPU/memory/PID enforcement with Core enabled.
4. Registry, filesystem, DNS, port and interactive compatibility.
5. Compose, BuildKit and real application/tool integrations.
6. Separate Swarm and advanced profiles when included in product scope.
7. Exact optimized installed-package qualification, then original-format Kiri benchmarks.

The [task board](docker-compatibility-task-board.md) gives each starting contract
its own narrow task. An implementer replaces one failing method with a genuine
fixture, fixes the demonstrated defect, runs focused checks, records evidence,
and obtains review. Do not mark all 88 done because the inventory validates.

## Commands available now

```sh
PYTHONDONTWRITEBYTECODE=1 python3 benchmarks/compatibility/run.py --check
PYTHONDONTWRITEBYTECODE=1 python3 benchmarks/compatibility/test_inventory.py
# Deliberately fails until the selected real fixtures are implemented:
PYTHONDONTWRITEBYTECODE=1 python3 benchmarks/compatibility/run.py --profile single-host
PYTHONDONTWRITEBYTECODE=1 python3 benchmarks/compatibility/run.py --profile all
```

Keep fast inventory checks separate from product tests. During development the
expanded suite is opt-in and explicitly failing; do not break unrelated CI with
placeholder failures. Before release, DC-RELEASE must wire the completed required
profile and strict receipt verifier into the release workflow. Unit tests alone
must never authorize publication. Final Developer ID/notarization/stapling and
Homebrew package checks remain separate gates. Benchmark p50/p95/p99, sample
counts, failures and paired intervals retain the existing detailed-report format.

## Sources

- [Docker Engine API](https://docs.docker.com/reference/api/engine/)
- [Compose specification](https://docs.docker.com/reference/compose-file/)
- [Dockerfile reference](https://docs.docker.com/reference/dockerfile/)
- [Swarm concepts](https://docs.docker.com/engine/swarm/key-concepts/)
- [Installed 71-case baseline](installed-native-compatibility.md)
- Kiri issue URLs are attached per case in the manifest; reports supply
  reproductions, not proof that Conjet fails or that a closed fix was released.

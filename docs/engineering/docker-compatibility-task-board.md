# Expanded Docker compatibility task board

Plan: [Docker compatibility matrix](docker-compatibility-matrix-plan.md).

Each of the 88 matrix cases is a separate increment. Their test methods currently fail with UNIMPLEMENTED.
No runtime feature or compatibility result is marked complete by this planning change.

## INPROGRESS

### DC-BUILD-002 — Frontend metadata mount and identity

Title: Enforce the external Dockerfile frontend's OCI configuration.
Description: Support its read-only metadata mount, isolated network namespace and requested supplementary groups.
Is blocked by task: None; the rejected preset has been captured.
Acceptance Criteria: Validate the metadata source under the owned worker root, retain a verified descriptor, enforce read-only mount flags, match group/network behavior and prove cancellation unmounts it. Invalid sources remain rejected.
Problem and Evidence: ARTEX reaches `unsupported live BuildKit OCI preset`; its frontend adds `/run/config/buildkit/metadata`, a network namespace and group 0.
Approach: Implement the actual mount and identity semantics; do not add a policy hash that accepts unimplemented behavior.
Evidence: conjet-compat-evidence/rejected-frontend-policy.json and artex-policy.json on ExternalSSD.
Source: guest/launch-service/src/build_snapshot/bundle.rs and mounts.rs.
Review: Investigation complete; implementation remains outstanding.
Next Action: Add owned metadata descriptor transfer and focused mount/identity fixtures.

## UNDERREVIEW

### DC-BUILD-001 — Verified Docker Hub build mirror

Title: Separate BuildKit content downloads from runnable-image admission.
Description: Serve tags, manifest lists and verified blobs for ordinary Docker Hub build dependencies.
Is blocked by task: None.
Acceptance Criteria: ARTEX resolves and extracts its unchanged `docker/dockerfile:1` frontend. Reject corrupt/unauthorized content, unsafe repository paths and exceeded bounds. Existing sample builds and Core memory remain passing.
Problem and Evidence: The previous mirror accepted only fixture image references and closed unsupported tag requests without a response.
Approach: Dedicated bounded content-addressed cache; repository-scoped descriptor grants; preserve image/worker privilege admission.
Evidence: 36 focused Rust tests; ARTEX frontend downloaded and extracted; packaged smoke/memory receipts recorded in conjet-compat-evidence.
Source: jetstream/src/native/docker/build_mirror.rs and build_registry.rs.
Review: Pending independent review; does not qualify ARTEX execution or full Docker compatibility.
Next Action: Review the isolated increment and complete DC-BUILD-002 onward.

## DONE

No expanded compatibility case is qualified yet.

## BACKLOG

### DC-BUILD-003 — Frontend duplex protocol

Title: Carry stdin and stdout between BuildKit and its frontend without loss.
Description: Add owned, bounded bidirectional input/output to BuildRuntime operations.
Is blocked by task: DC-BUILD-002.
Acceptance Criteria: Frontend RPC completes; streams larger than 64 KiB are delivered exactly once; backpressure, EOF and cancellation terminate cleanly without orphaned processes.
Problem and Evidence: BuildOperation has no stdin operation; process_spec sets open_stdin false; current output is retained under a fixed workload budget.
Approach: Reuse workload input primitives and introduce acknowledged bounded stream consumption under the verified execution handle.
Evidence: Source inspection; runtime acceptance pending.
Source: guest/launch-service/src/build_runtime.rs; fresh_fixture.rs; workload_input.rs.
Review: Pending.
Next Action: Add a round-trip streaming fixture before enabling frontend execution.

### DC-BUILD-004 — Concurrent build execution ownership

Title: Run independent BuildKit executions concurrently.
Description: Replace the single ActiveBuild slot with bounded per-worker execution ownership.
Is blocked by task: DC-BUILD-003.
Acceptance Criteria: A frontend and two independent RUN steps overlap; identities, output, roots and cancellation cannot cross workers; all owned resources are reconciled on shutdown.
Problem and Evidence: BuildRuntime currently retains one active execution.
Approach: Key execution state by worker generation and runtime ID; enforce a capacity limit and per-execution cleanup.
Evidence: Source inspection; runtime acceptance pending.
Source: guest/launch-service/src/fresh_fixture.rs.
Review: Pending.
Next Action: Implement ownership tests and concurrent lifecycle fixtures.

### DC-BUILD-005 — Long RUN cancellation and timeout

Title: Support RUN steps beyond the fixture's 33-second wait.
Description: Tie runtime lifetime to the owned build session and explicit cancellation policy.
Is blocked by task: DC-BUILD-004.
Acceptance Criteria: A 60-second RUN completes; canceled and disconnected builds stop only their own execution; timeout errors remain explicit; memory and mounts are reclaimed.
Problem and Evidence: build_runtime.rs uses a fixed 33-second wait deadline.
Approach: Define a supported session timeout, propagate cancellation and retain bounded control-request deadlines.
Evidence: Source inspection; runtime acceptance pending.
Source: guest/launch-service/src/build_runtime.rs.
Review: Pending.
Next Action: Reproduce duration failure and add cancellation/disconnection checks.

### DC-BUILD-006 — Unchanged ARTEX package acceptance

Title: Complete ARTEX's Compose build on an isolated installed package.
Description: Reuse the actual ARTEX project without Dockerfile edits, secret loading or service startup.
Is blocked by task: DC-BUILD-001 through DC-BUILD-005.
Acceptance Criteria: All frontend, Node, Go, Debian and Python stages complete; exported image is inspectable; a warm rebuild succeeds; Core canary and standard Docker E2E pass on the same package. Record additional discovered gaps as tasks instead of changing ARTEX.
Problem and Evidence: The current build stops at frontend admission before any application stage.
Approach: Run native-fresh-buildx.py --compose-project against a verified optimized DMG extraction and a fresh private profile.
Evidence: Current failed reproducer and cleanup receipts are retained on ExternalSSD.
Source: ARTEX/Dockerfile; ARTEX/docker-compose.yml; benchmarks/native-fresh-buildx.py.
Review: Pending.
Next Action: Rerun after the preceding execution features pass.

### DC-INFRA — Isolated differential fixture harness

Title: Run one fixture against explicit reference Docker and Conjet endpoints.
Description: Implement owned-resource cleanup, endpoint identity checks, bounded subprocesses and evidence receipts before replacing any case contract.
Is blocked by task: None.
Acceptance Criteria: Refuse default/production endpoints, non-ExternalSSD data roots and missing artifact identities; interrupt and timeout clean only task-owned resources; negative tests prove refusal.
Problem and Evidence: Existing 71-case qualification does not cover this expanded inventory.
Approach: Reuse isolated lifecycle tooling; require explicit reference and candidate sockets; never switch global context.
Evidence: Pending.
Source: benchmarks/compatibility/matrix.json; existing run-conjet-speedup.py.
Review: Pending.
Next Action: Map reusable launcher contracts and implement harness tests.

### DC-SPEC — Freeze feature and version inventory

Title: Audit pinned Engine API and Compose schema coverage.
Description: Record actual reference engine/API versions and upstream schema commits; enumerate every endpoint, request field and Compose key into covered, unsupported or not-applicable rows.
Is blocked by task: None.
Acceptance Criteria: No schema field silently omitted; platform exclusions justified; compound matrix rows split into parametrized cases; every advertised feature has enforcement evidence requirements.
Problem and Evidence: 88 starting contracts are not an exhaustive API schema audit.
Approach: Compare official pinned schemas to native adapter routes and guest capabilities; preserve original 71 cases.
Evidence: Pending.
Source: Docker Engine API and Compose specification.
Review: Pending.
Next Action: Freeze official specification revisions.

### DC-001 — version-negotiation

Title: Qualify version-negotiation.
Description: Negotiate supported API versions; reject unsupported versions without mutation.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Negotiate supported API versions; reject unsupported versions without mutation. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded api behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_api.py::test_version_negotiation with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-001 after harness and specification prerequisites pass.

### DC-002 — response-contracts

Title: Qualify response-contracts.
Description: Compare status codes, null versus absent fields, errors and filters with reference Docker.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Compare status codes, null versus absent fields, errors and filters with reference Docker. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded api behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_api.py::test_response_contracts with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-002 after harness and specification prerequisites pass.

### DC-003 — http-framing

Title: Qualify http-framing.
Description: Exercise chunked trailers, Expect, keepalive and Connection close without losing request boundaries.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Exercise chunked trailers, Expect, keepalive and Connection close without losing request boundaries. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded api behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_api.py::test_http_framing with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-003 after harness and specification prerequisites pass.

### DC-004 — exec-exit

Title: Qualify exec-exit.
Description: Java and Python SDK exec returns complete stdout, stderr and integer terminal exit status.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Java and Python SDK exec returns complete stdout, stderr and integer terminal exit status. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded api behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_api.py::test_exec_exit with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/551
Review: Pending independent review.
Next Action: Implement only DC-004 after harness and specification prerequisites pass.

### DC-005 — network-connect-status

Title: Qualify network-connect-status.
Description: Node Testcontainers connects an alias network and resolves its peer successfully.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Node Testcontainers connects an alias network and resolves its peer successfully. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded api behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_api.py::test_network_connect_status with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/878
Review: Pending independent review.
Next Action: Implement only DC-005 after harness and specification prerequisites pass.

### DC-006 — inspect-recreate

Title: Qualify inspect-recreate.
Description: Recreate from inspect metadata and preserve mounts, ports, environment and labels.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Recreate from inspect metadata and preserve mounts, ports, environment and labels. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded api behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_api.py::test_inspect_recreate with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/610
Review: Pending independent review.
Next Action: Implement only DC-006 after harness and specification prerequisites pass.

### DC-007 — durable-container

Title: Qualify durable-container.
Description: Write a checksum to a container layer; restart engine; start same container and verify bytes and metadata.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Write a checksum to a container layer; restart engine; start same container and verify bytes and metadata. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded lifecycle behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_lifecycle.py::test_durable_container with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-007 after harness and specification prerequisites pass.

### DC-008 — durable-tags

Title: Qualify durable-tags.
Description: Local image aliases resolve to the same image after engine restart.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Local image aliases resolve to the same image after engine restart. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded lifecycle behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_lifecycle.py::test_durable_tags with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-008 after harness and specification prerequisites pass.

### DC-009 — restart-policy

Title: Qualify restart-policy.
Description: Verify no, always, unless-stopped and on-failure across exit, explicit stop and engine restart.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Verify no, always, unless-stopped and on-failure across exit, explicit stop and engine restart. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded lifecycle behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_lifecycle.py::test_restart_policy with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-009 after harness and specification prerequisites pass.

### DC-010 — signal-init

Title: Qualify signal-init.
Description: PID 1 receives configured stop signal; init reaps zombies; timeout escalates and reports exit correctly.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: PID 1 receives configured stop signal; init reaps zombies; timeout escalates and reports exit correctly. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded lifecycle behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_lifecycle.py::test_signal_init with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-010 after harness and specification prerequisites pass.

### DC-011 — pause-update

Title: Qualify pause-update.
Description: Pause freezes progress; unpause resumes; resource update preserves unrelated configuration.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Pause freezes progress; unpause resumes; resource update preserves unrelated configuration. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded lifecycle behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_lifecycle.py::test_pause_update with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-011 after harness and specification prerequisites pass.

### DC-012 — name-races

Title: Qualify name-races.
Description: Concurrent create with one name admits one owner; failed start releases only its owned resources.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Concurrent create with one name admits one owner; failed start releases only its owned resources. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded lifecycle behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_lifecycle.py::test_name_races with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-012 after harness and specification prerequisites pass.

### DC-013 — lost-guest-reply

Title: Qualify lost-guest-reply.
Description: Drop a guest reply; request times out and unrelated info and cancellation remain responsive.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Drop a guest reply; request times out and unrelated info and cancellation remain responsive. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded lifecycle behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_lifecycle.py::test_lost_guest_reply with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/948
Review: Pending independent review.
Next Action: Implement only DC-013 after harness and specification prerequisites pass.

### DC-014 — disk-full-recovery

Title: Qualify disk-full-recovery.
Description: Fill isolated disk during write and pull; reclaim owned data; restart and verify recovery and original checksums.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Fill isolated disk during write and pull; reclaim owned data; restart and verify recovery and original checksums. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded lifecycle behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_lifecycle.py::test_disk_full_recovery with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-014 after harness and specification prerequisites pass.

### DC-015 — attach-reconnect

Title: Qualify attach-reconnect.
Description: StdinOnce false survives attach disconnect and reconnect without premature EOF.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: StdinOnce false survives attach disconnect and reconnect without premature EOF. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded interactive behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_interactive.py::test_attach_reconnect with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/128
Review: Pending independent review.
Next Action: Implement only DC-015 after harness and specification prerequisites pass.

### DC-016 — tty-resize

Title: Qualify tty-resize.
Description: TTY allocation and resize update guest dimensions; non-TTY stdout and stderr remain separate.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: TTY allocation and resize update guest dimensions; non-TTY stdout and stderr remain separate. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded interactive behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_interactive.py::test_tty_resize with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-016 after harness and specification prerequisites pass.

### DC-017 — detach-keys

Title: Qualify detach-keys.
Description: Detach sequence split across reads detaches without dropping ordinary input or stopping container.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Detach sequence split across reads detaches without dropping ordinary input or stopping container. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded interactive behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_interactive.py::test_detach_keys with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/128
Review: Pending independent review.
Next Action: Implement only DC-017 after harness and specification prerequisites pass.

### DC-018 — websocket-attach

Title: Qualify websocket-attach.
Description: WebSocket masking, ping, close, backpressure and disconnect have bounded memory and correct stream behavior.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: WebSocket masking, ping, close, backpressure and disconnect have bounded memory and correct stream behavior. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded interactive behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_interactive.py::test_websocket_attach with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/128
Review: Pending independent review.
Next Action: Implement only DC-018 after harness and specification prerequisites pass.

### DC-019 — cap-drop

Title: Qualify cap-drop.
Description: Drop ALL; inspect capability sets and prove a capability-dependent operation fails.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Drop ALL; inspect capability sets and prove a capability-dependent operation fails. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded security behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_security.py::test_cap_drop with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-019 after harness and specification prerequisites pass.

### DC-020 — cap-add

Title: Qualify cap-add.
Description: Add NET_ADMIN in a private network namespace; permitted operation succeeds without unrelated capabilities.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Add NET_ADMIN in a private network namespace; permitted operation succeeds without unrelated capabilities. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded security behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_security.py::test_cap_add with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-020 after harness and specification prerequisites pass.

### DC-021 — read-only

Title: Qualify read-only.
Description: Rootfs write fails while writable named volume succeeds.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Rootfs write fails while writable named volume succeeds. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded security behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_security.py::test_read_only with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-021 after harness and specification prerequisites pass.

### DC-022 — no-new-privileges

Title: Qualify no-new-privileges.
Description: Kernel NoNewPrivs is set and a controlled setuid elevation is denied.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Kernel NoNewPrivs is set and a controlled setuid elevation is denied. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded security behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_security.py::test_no_new_privileges with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-022 after harness and specification prerequisites pass.

### DC-023 — seccomp

Title: Qualify seccomp.
Description: Configured syscall allow and deny behavior matches policy; unsupported profiles fail before start.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Configured syscall allow and deny behavior matches policy; unsupported profiles fail before start. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded security behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_security.py::test_seccomp with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-023 after harness and specification prerequisites pass.

### DC-024 — namespace-sharing

Title: Qualify namespace-sharing.
Description: Verify private, host and container PID and IPC modes against guest identities without contaminating supervisor namespaces.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Verify private, host and container PID and IPC modes against guest identities without contaminating supervisor namespaces. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded security behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_security.py::test_namespace_sharing with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-024 after harness and specification prerequisites pass.

### DC-025 — privileged-devices

Title: Qualify privileged-devices.
Description: Verify supported privileged and device access remains within VM boundary; unsupported requests fail explicitly.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Verify supported privileged and device access remains within VM boundary; unsupported requests fail explicitly. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded security behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_security.py::test_privileged_devices with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-025 after harness and specification prerequisites pass.

### DC-026 — cpu-quota

Title: Qualify cpu-quota.
Description: Quota is applied and sustained load shows throttling; removing quota preserves other limits.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Quota is applied and sustained load shows throttling; removing quota preserves other limits. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded limits behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_limits.py::test_cpu_quota with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/129
Review: Pending independent review.
Next Action: Implement only DC-026 after harness and specification prerequisites pass.

### DC-027 — cpu-affinity

Title: Qualify cpu-affinity.
Description: Requested available CPUs constrain execution; invalid CPU sets are rejected atomically.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Requested available CPUs constrain execution; invalid CPU sets are rejected atomically. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded limits behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_limits.py::test_cpu_affinity with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/129
Review: Pending independent review.
Next Action: Implement only DC-027 after harness and specification prerequisites pass.

### DC-028 — memory-oom

Title: Qualify memory-oom.
Description: Hard limit triggers expected OOM state while sibling workload remains healthy.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Hard limit triggers expected OOM state while sibling workload remains healthy. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded limits behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_limits.py::test_memory_oom with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-028 after harness and specification prerequisites pass.

### DC-029 — reservation-swap

Title: Qualify reservation-swap.
Description: Reservation and memory-plus-swap combinations match reference cgroup behavior; unsupported settings are explicit.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Reservation and memory-plus-swap combinations match reference cgroup behavior; unsupported settings are explicit. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded limits behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_limits.py::test_reservation_swap with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/129; https://github.com/libracoder/kiri/issues/523
Review: Pending independent review.
Next Action: Implement only DC-029 after harness and specification prerequisites pass.

### DC-030 — pids-ulimits

Title: Qualify pids-ulimits.
Description: Fork and file-open fixtures hit configured PID and descriptor limits without exhausting guest.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Fork and file-open fixtures hit configured PID and descriptor limits without exhausting guest. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded limits behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_limits.py::test_pids_ulimits with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-030 after harness and specification prerequisites pass.

### DC-031 — transactional-update

Title: Qualify transactional-update.
Description: Invalid multi-field update leaves all previously effective limits unchanged.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Invalid multi-field update leaves all previously effective limits unchanged. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded limits behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_limits.py::test_transactional_update with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-031 after harness and specification prerequisites pass.

### DC-032 — idle-burst

Title: Qualify idle-burst.
Description: Database stays healthy through idle reclaim then a workload burst; verify growth and data integrity.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Database stays healthy through idle reclaim then a workload burst; verify growth and data integrity. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded core behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_core.py::test_idle_burst with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/891
Review: Pending independent review.
Next Action: Implement only DC-032 after harness and specification prerequisites pass.

### DC-033 — reclaim-stability

Title: Qualify reclaim-stability.
Description: Eight-hour idle-stack soak measures host footprint, guest pressure, faults and IO without recurring reclaim oscillation.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Eight-hour idle-stack soak measures host footprint, guest pressure, faults and IO without recurring reclaim oscillation. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded core behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_core.py::test_reclaim_stability with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/646
Review: Pending independent review.
Next Action: Implement only DC-033 after harness and specification prerequisites pass.

### DC-034 — mixed-pressure

Title: Qualify mixed-pressure.
Description: Concurrent database and build under pressure preserve checksums, limits and bounded preparation eviction.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Concurrent database and build under pressure preserve checksums, limits and bounded preparation eviction. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded core behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_core.py::test_mixed_pressure with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-034 after harness and specification prerequisites pass.

### DC-035 — general-references

Title: Qualify general-references.
Description: Pull mutable tags and digests from public and private registries; resolve correct platform and immutable identity.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Pull mutable tags and digests from public and private registries; resolve correct platform and immutable identity. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded images behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_images.py::test_general_references with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-035 after harness and specification prerequisites pass.

### DC-036 — auth-null-fields

Title: Qualify auth-null-fields.
Description: SDK authentication with optional null fields works; invalid and expired tokens fail without leaking credentials.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: SDK authentication with optional null fields works; invalid and expired tokens fail without leaking credentials. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded images behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_images.py::test_auth_null_fields with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/654
Review: Pending independent review.
Next Action: Implement only DC-036 after harness and specification prerequisites pass.

### DC-037 — registry-tls

Title: Qualify registry-tls.
Description: Custom CA and proxy paths work; untrusted certificates and cross-origin credential forwarding are rejected.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Custom CA and proxy paths work; untrusted certificates and cross-origin credential forwarding are rejected. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded images behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_images.py::test_registry_tls with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-037 after harness and specification prerequisites pass.

### DC-038 — push-digests

Title: Qualify push-digests.
Description: Push and pull roundtrip preserve manifest identity; RepoDigests contains registry digest rather than config ID.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Push and pull roundtrip preserve manifest identity; RepoDigests contains registry digest rather than config ID. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded images behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_images.py::test_push_digests with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-038 after harness and specification prerequisites pass.

### DC-039 — diffids-scanner

Title: Qualify diffids-scanner.
Description: Inspect RootFS diff IDs match saved archive; Trivy can scan through Docker API.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Inspect RootFS diff IDs match saved archive; Trivy can scan through Docker API. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded images behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_images.py::test_diffids_scanner with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/573
Review: Pending independent review.
Next Action: Implement only DC-039 after harness and specification prerequisites pass.

### DC-040 — archive-roundtrip

Title: Qualify archive-roundtrip.
Description: Save and load compressed and multi-image archives preserving tags, metadata and runnable contents.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Save and load compressed and multi-image archives preserving tags, metadata and runnable contents. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded images behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_images.py::test_archive_roundtrip with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-040 after harness and specification prerequisites pass.

### DC-041 — concurrent-ingest

Title: Qualify concurrent-ingest.
Description: Concurrent loads sharing layers and canceled transfers preserve atomic image publication and reference counts.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Concurrent loads sharing layers and canceled transfers preserve atomic image publication and reference counts. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded images behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_images.py::test_concurrent_ingest with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/756
Review: Pending independent review.
Next Action: Implement only DC-041 after harness and specification prerequisites pass.

### DC-042 — prune-references

Title: Qualify prune-references.
Description: Prune and replacement reclaim only unused content; referenced image and layer data remain intact.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Prune and replacement reclaim only unused content; referenced image and layer data remain intact. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded images behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_images.py::test_prune_references with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/864; https://github.com/libracoder/kiri/issues/722
Review: Pending independent review.
Next Action: Implement only DC-042 after harness and specification prerequisites pass.

### DC-043 — volume-in-use

Title: Qualify volume-in-use.
Description: Force removal of a volume referenced by running or stopped container is refused and checksum survives.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Force removal of a volume referenced by running or stopped container is refused and checksum survives. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded storage behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_storage.py::test_volume_in_use with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/773
Review: Pending independent review.
Next Action: Implement only DC-043 after harness and specification prerequisites pass.

### DC-044 — volume-copyup

Title: Qualify volume-copyup.
Description: Named and anonymous volume population, nocopy, UID and mode match reference behavior.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Named and anonymous volume population, nocopy, UID and mode match reference behavior. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded storage behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_storage.py::test_volume_copyup with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-044 after harness and specification prerequisites pass.

### DC-045 — archive-ownership

Title: Qualify archive-ownership.
Description: Copy in and out preserve expected UID, GID, mode, links and directory-content semantics.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Copy in and out preserve expected UID, GID, mode, links and directory-content semantics. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded storage behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_storage.py::test_archive_ownership with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/741; https://github.com/libracoder/kiri/issues/617
Review: Pending independent review.
Next Action: Implement only DC-045 after harness and specification prerequisites pass.

### DC-046 — host-file-events

Title: Qualify host-file-events.
Description: Host create, atomic save, rename and delete emit events and trigger application reload.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Host create, atomic save, rename and delete emit events and trigger application reload. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded storage behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_storage.py::test_host_file_events with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/531
Review: Pending independent review.
Next Action: Implement only DC-046 after harness and specification prerequisites pass.

### DC-047 — host-permissions

Title: Qualify host-permissions.
Description: Parallel non-root creates and renames preserve permission semantics without intermittent EACCES.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Parallel non-root creates and renames preserve permission semantics without intermittent EACCES. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded storage behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_storage.py::test_host_permissions with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/796
Review: Pending independent review.
Next Action: Implement only DC-047 after harness and specification prerequisites pass.

### DC-048 — filesystem-metadata

Title: Qualify filesystem-metadata.
Description: Exercise xattrs, hardlinks, sparse files, locking and fsync on supported mount types.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Exercise xattrs, hardlinks, sparse files, locking and fsync on supported mount types. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded storage behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_storage.py::test_filesystem_metadata with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-048 after harness and specification prerequisites pass.

### DC-049 — mount-paths

Title: Qualify mount-paths.
Description: Bind ExternalSSD paths with spaces and Unicode; distinguish host case sensitivity from guest volume behavior.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Bind ExternalSSD paths with spaces and Unicode; distinguish host case sensitivity from guest volume behavior. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded storage behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_storage.py::test_mount_paths with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-049 after harness and specification prerequisites pass.

### DC-050 — tmpfs-options

Title: Qualify tmpfs-options.
Description: Tmpfs size, UID, GID and mode apply even when image target directory is absent.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Tmpfs size, UID, GID and mode apply even when image target directory is absent. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded storage behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_storage.py::test_tmpfs_options with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-050 after harness and specification prerequisites pass.

### DC-051 — project-dns

Title: Qualify project-dns.
Description: Two Compose projects using same service names resolve only their own peers.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Two Compose projects using same service names resolve only their own peers. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded network behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_network.py::test_project_dns with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/294
Review: Pending independent review.
Next Action: Implement only DC-051 after harness and specification prerequisites pass.

### DC-052 — application-dns

Title: Qualify application-dns.
Description: Go gRPC, Node and JVM resolvers connect successfully over sustained requests.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Go gRPC, Node and JVM resolvers connect successfully over sustained requests. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded network behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_network.py::test_application_dns with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/715
Review: Pending independent review.
Next Action: Implement only DC-052 after harness and specification prerequisites pass.

### DC-053 — network-mutation

Title: Qualify network-mutation.
Description: Connect and disconnect first and secondary networks; update aliases and release DNS listeners.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Connect and disconnect first and secondary networks; update aliases and release DNS listeners. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded network behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_network.py::test_network_mutation with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/789; https://github.com/libracoder/kiri/issues/248
Review: Pending independent review.
Next Action: Implement only DC-053 after harness and specification prerequisites pass.

### DC-054 — internal-isolation

Title: Qualify internal-isolation.
Description: Internal network prevents egress while allowed peers communicate; configured bridge isolation is enforced.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Internal network prevents egress while allowed peers communicate; configured bridge isolation is enforced. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded network behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_network.py::test_internal_isolation with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-054 after harness and specification prerequisites pass.

### DC-055 — ports

Title: Qualify ports.
Description: TCP and UDP publication, loopback versus LAN binding, ephemeral ports and collisions match selected platform contract.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: TCP and UDP publication, loopback versus LAN binding, ephemeral ports and collisions match selected platform contract. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded network behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_network.py::test_ports with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-055 after harness and specification prerequisites pass.

### DC-056 — idle-stream

Title: Qualify idle-stream.
Description: Keep a TCP session idle beyond five minutes then transfer bytes without unexpected disconnect.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Keep a TCP session idle beyond five minutes then transfer bytes without unexpected disconnect. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded network behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_network.py::test_idle_stream with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/530
Review: Pending independent review.
Next Action: Implement only DC-056 after harness and specification prerequisites pass.

### DC-057 — host-access

Title: Qualify host-access.
Description: Reach macOS IPv4 and IPv6 loopback services using documented host gateway behavior.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Reach macOS IPv4 and IPv6 loopback services using documented host gateway behavior. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded network behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_network.py::test_host_access with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-057 after harness and specification prerequisites pass.

### DC-058 — dual-stack

Title: Qualify dual-stack.
Description: IPv4 and IPv6 static endpoints, IPAM and inspection agree with actual connectivity.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: IPv4 and IPv6 static endpoints, IPAM and inspection agree with actual connectivity. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded network behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_network.py::test_dual_stack with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-058 after harness and specification prerequisites pass.

### DC-059 — vpn-proxy

Title: Qualify vpn-proxy.
Description: Approved split-tunnel VPN and proxy fixtures resolve and route correctly without altering host networking globally.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Approved split-tunnel VPN and proxy fixtures resolve and route correctly without altering host networking globally. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded network behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_network.py::test_vpn_proxy with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-059 after harness and specification prerequisites pass.

### DC-060 — dockerfile

Title: Qualify dockerfile.
Description: Test each pinned Dockerfile instruction and flag through separate parametrized fixtures, including multi-stage and ignore rules.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Test each pinned Dockerfile instruction and flag through separate parametrized fixtures, including multi-stage and ignore rules. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded build behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_build.py::test_dockerfile with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-060 after harness and specification prerequisites pass.

### DC-061 — cache-invalidation

Title: Qualify cache-invalidation.
Description: Unchanged, source-only and dependency changes reuse only valid cache; outputs have expected checksums.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Unchanged, source-only and dependency changes reuse only valid cache; outputs have expected checksums. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded build behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_build.py::test_cache_invalidation with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-061 after harness and specification prerequisites pass.

### DC-062 — secret-ssh

Title: Qualify secret-ssh.
Description: Secret and SSH sessions work; secret material is absent from final image, history and exported cache.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Secret and SSH sessions work; secret material is absent from final image, history and exported cache. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded build behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_build.py::test_secret_ssh with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-062 after harness and specification prerequisites pass.

### DC-063 — drivers

Title: Qualify drivers.
Description: Qualify default docker and docker-container drivers separately with explicit capability reporting.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Qualify default docker and docker-container drivers separately with explicit capability reporting. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded build behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_build.py::test_drivers with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/49
Review: Pending independent review.
Next Action: Implement only DC-063 after harness and specification prerequisites pass.

### DC-064 — outputs

Title: Qualify outputs.
Description: Load, OCI, local and registry outputs preserve identity; built image is immediately inspectable and runnable.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Load, OCI, local and registry outputs preserve identity; built image is immediately inspectable and runnable. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded build behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_build.py::test_outputs with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-064 after harness and specification prerequisites pass.

### DC-065 — cancel-concurrent

Title: Qualify cancel-concurrent.
Description: Concurrent builds plus cancellation clean mounts and processes without corrupting cache or sibling build.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Concurrent builds plus cancellation clean mounts and processes without corrupting cache or sibling build. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded build behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_build.py::test_cancel_concurrent with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-065 after harness and specification prerequisites pass.

### DC-066 — contexts-bake

Title: Qualify contexts-bake.
Description: Named and remote contexts, cache import/export and Bake targets produce expected artifacts.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Named and remote contexts, cache import/export and Bake targets produce expected artifacts. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded build behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_build.py::test_contexts_bake with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-066 after harness and specification prerequisites pass.

### DC-067 — config-resolution

Title: Qualify config-resolution.
Description: Overrides, interpolation, env files, profiles, includes and relative paths match pinned official Compose processing.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Overrides, interpolation, env files, profiles, includes and relative paths match pinned official Compose processing. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded compose behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_compose.py::test_config_resolution with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-067 after harness and specification prerequisites pass.

### DC-068 — health-dependencies

Title: Qualify health-dependencies.
Description: Started, healthy and completed dependencies plus up wait enforce actual readiness and failure semantics.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Started, healthy and completed dependencies plus up wait enforce actual readiness and failure semantics. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded compose behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_compose.py::test_health_dependencies with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-068 after harness and specification prerequisites pass.

### DC-069 — resource-fields

Title: Qualify resource-fields.
Description: Compose limits, reservations and capabilities reach actual cgroup and process state; no silent ineffective settings.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Compose limits, reservations and capabilities reach actual cgroup and process state; no silent ineffective settings. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded compose behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_compose.py::test_resource_fields with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-069 after harness and specification prerequisites pass.

### DC-070 — secrets-configs

Title: Qualify secrets-configs.
Description: File and supported environment sources mount with correct targets and access; missing sources fail before start.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: File and supported environment sources mount with correct targets and access; missing sources fail before start. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded compose behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_compose.py::test_secrets_configs with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-070 after harness and specification prerequisites pass.

### DC-071 — lifecycle-scale

Title: Qualify lifecycle-scale.
Description: Scale, recreate, restart, orphan removal and down preserve or remove resources according to flags.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Scale, recreate, restart, orphan removal and down preserve or remove resources according to flags. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded compose behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_compose.py::test_lifecycle_scale with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-071 after harness and specification prerequisites pass.

### DC-072 — watch-hooks

Title: Qualify watch-hooks.
Description: Supported watch and lifecycle hooks execute in correct order; failures and unsupported configuration are explicit.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Supported watch and lifecycle hooks execute in correct order; failures and unsupported configuration are explicit. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded compose behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_compose.py::test_watch_hooks with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-072 after harness and specification prerequisites pass.

### DC-073 — build-pull-policy

Title: Qualify build-pull-policy.
Description: Up build and pull policy select correct artifact; project build secrets and additional contexts function.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Up build and pull policy select correct artifact; project build secrets and additional contexts function. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded compose behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_compose.py::test_build_pull_policy with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-073 after harness and specification prerequisites pass.

### DC-074 — testcontainers

Title: Qualify testcontainers.
Description: Run pinned Java, Node, Python, Go and .NET fixtures including readiness, exec, networks and cleanup.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Run pinned Java, Node, Python, Go and .NET fixtures including readiness, exec, networks and cleanup. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded ecosystem behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_ecosystem.py::test_testcontainers with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-074 after harness and specification prerequisites pass.

### DC-075 — devcontainers

Title: Qualify devcontainers.
Description: Open a pinned development fixture with mounts, non-root user, exec and rebuild; verify file edits.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Open a pinned development fixture with mounts, non-root user, exec and rebuild; verify file edits. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded ecosystem behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_ecosystem.py::test_devcontainers with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-075 after harness and specification prerequisites pass.

### DC-076 — database-stack

Title: Qualify database-stack.
Description: Application plus PostgreSQL, Redis and reverse proxy serves requests across recreate and engine restart.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Application plus PostgreSQL, Redis and reverse proxy serves requests across recreate and engine restart. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded ecosystem behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_ecosystem.py::test_database_stack with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-076 after harness and specification prerequisites pass.

### DC-077 — help-no-effects

Title: Qualify help-no-effects.
Description: All help and version commands leave processes, Docker config, shell profiles and startup registrations unchanged.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: All help and version commands leave processes, Docker config, shell profiles and startup registrations unchanged. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded product behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_product.py::test_help_no_effects with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/982
Review: Pending independent review.
Next Action: Implement only DC-077 after harness and specification prerequisites pass.

### DC-078 — socket-coexistence

Title: Qualify socket-coexistence.
Description: Explicit test context remains isolated; startup and stop do not replace production socket or selected context.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Explicit test context remains isolated; startup and stop do not replace production socket or selected context. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded product behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_product.py::test_socket_coexistence with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-078 after harness and specification prerequisites pass.

### DC-079 — upgrade-rollback

Title: Qualify upgrade-rollback.
Description: Installed candidate preserves supported data across upgrade and documented rollback using isolated copies.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Installed candidate preserves supported data across upgrade and documented rollback using isolated copies. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded product behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_product.py::test_upgrade_rollback with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-079 after harness and specification prerequisites pass.

### DC-080 — single-node

Title: Qualify single-node.
Description: Init and leave plus service create, inspect and remove expose correct task lifecycle.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Init and leave plus service create, inspect and remove expose correct task lifecycle. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded swarm behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_swarm.py::test_single_node with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: https://github.com/libracoder/kiri/issues/603
Review: Pending independent review.
Next Action: Implement only DC-080 after harness and specification prerequisites pass.

### DC-081 — update-rollback

Title: Qualify update-rollback.
Description: Rolling service update, failure rollback, replicas and job modes follow declared policy.
Is blocked by task: DC-INFRA, DC-SPEC, DC-080.
Acceptance Criteria: Rolling service update, failure rollback, replicas and job modes follow declared policy. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded swarm behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_swarm.py::test_update_rollback with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-081 after harness and specification prerequisites pass.

### DC-082 — secrets-configs

Title: Qualify secrets-configs.
Description: Service secrets and configs have expected permissions, lifecycle and access restrictions.
Is blocked by task: DC-INFRA, DC-SPEC, DC-080.
Acceptance Criteria: Service secrets and configs have expected permissions, lifecycle and access restrictions. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded swarm behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_swarm.py::test_secrets_configs with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-082 after harness and specification prerequisites pass.

### DC-083 — overlay-routing

Title: Qualify overlay-routing.
Description: Multi-node overlay discovery, VIP and routing mesh reach healthy tasks across nodes.
Is blocked by task: DC-INFRA, DC-SPEC, DC-080.
Acceptance Criteria: Multi-node overlay discovery, VIP and routing mesh reach healthy tasks across nodes. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded swarm behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_swarm.py::test_overlay_routing with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-083 after harness and specification prerequisites pass.

### DC-084 — quorum-recovery

Title: Qualify quorum-recovery.
Description: Three managers survive leader loss; partition and recovery preserve agreed state without duplicate ownership.
Is blocked by task: DC-INFRA, DC-SPEC, DC-080.
Acceptance Criteria: Three managers survive leader loss; partition and recovery preserve agreed state without duplicate ownership. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded swarm behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_swarm.py::test_quorum_recovery with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-084 after harness and specification prerequisites pass.

### DC-085 — amd64

Title: Qualify amd64.
Description: Foreign-platform pull, build and execution use emulation correctly or fail explicitly before execution.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Foreign-platform pull, build and execution use emulation correctly or fail explicitly before execution. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded advanced behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_advanced.py::test_amd64 with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-085 after harness and specification prerequisites pass.

### DC-086 — plugins

Title: Qualify plugins.
Description: Each advertised volume, network and logging plugin contract passes lifecycle and failure tests.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Each advertised volume, network and logging plugin contract passes lifecycle and failure tests. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded advanced behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_advanced.py::test_plugins with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-086 after harness and specification prerequisites pass.

### DC-087 — gpu-cdi

Title: Qualify gpu-cdi.
Description: Advertised GPU or CDI devices perform a real workload; unavailable hardware is not reported as supported.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Advertised GPU or CDI devices perform a real workload; unavailable hardware is not reported as supported. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded advanced behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_advanced.py::test_gpu_cdi with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-087 after harness and specification prerequisites pass.

### DC-088 — rootless-checkpoint

Title: Qualify rootless-checkpoint.
Description: Rootless and checkpoint restore require separate declared capability fixtures; unsupported modes remain explicit.
Is blocked by task: DC-INFRA, DC-SPEC.
Acceptance Criteria: Rootless and checkpoint restore require separate declared capability fixtures; unsupported modes remain explicit. Positive, invalid-input and cleanup checks pass against pinned reference and candidate; restart/failure variants apply where state persists.
Problem and Evidence: Expanded advanced behavior is UNTESTED; 71/71 does not establish this case.
Approach: Replace cases/test_advanced.py::test_rootless_checkpoint with a real bounded fixture; reproduce difference before changing engine; add focused Rust/Swift regression tests for defects.
Evidence: Pending; no runtime checks executed.
Source: Pinned official Docker specification; see matrix plan.
Review: Pending independent review.
Next Action: Implement only DC-088 after harness and specification prerequisites pass.

### DC-RELEASE — Installed package qualification

Title: Enforce expanded compatibility on the exact final release candidate.
Description: Run selected release profile, retained 71-case gate, package checks and comparative benchmarks against exact optimized artifacts.
Is blocked by task: All cases required by the reviewed release scope; DC-INFRA; DC-SPEC.
Acceptance Criteria: No required skip, missing, unsupported or failed case; evidence bound to package hashes and manifest hash; cleanup verified; benchmark errors retained separately; required CI/review/signing checks pass.
Problem and Evidence: Inventory validation and placeholder tests cannot qualify a release.
Approach: Add receipt verification and release-workflow gating after real fixtures exist; run final installed package from ExternalSSD with production fingerprints before/after.
Evidence: Pending.
Source: installed-native-compatibility.md; docker-benchmark-results.md.
Review: Pending.
Next Action: Define strict receipt schema and tests for forged/mismatched/missing evidence.

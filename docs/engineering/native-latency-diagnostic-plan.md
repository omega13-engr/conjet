# Diagnose the native lifecycle above 5 ms

Status: investigation plan, not an optimization result. Source baseline:
`a46f820`; preserve any newer worker changes. Scope: fresh ARM64 native
Docker API lifecycle with Core dynamic memory enabled. Production is untouched.

## Evidence and architecture assessment

The latest two release pilot pairs measured API p50 39.53–40.35 ms and
p99 73.13–75.10 ms, versus Kiri p50 3.82–3.87 ms. All 1,600 operations
passed. The pilot is not full qualification and predates the snapshot
ID-mapping change. Reproduce on a frozen current revision before comparing.
[Evidence](native-engine-validation.md#speed-065-current-release-pilot)

SPEED-060 already removed a measured approval-to-send delay: 32.99 ms
median became 0.012 ms. Its trace begins after observation; it does not
measure how long a newly pending guest request waits to be discovered.
[Prior attribution](native-engine-validation.md#speed-060)

| Component | Source observation | Assessment |
| --- | --- | --- |
| Guest admission discovery | `session.rs` fetches a Memory observation, publishes it, then in event mode waits for approval with a 30 ms timeout | Leading hypothesis: new pending work cannot itself wake an approval-only wait; it may wait for the next observation. Measure before changing. |
| Controller approval | Existing Core policy approves observed demand | Keep policy and capacity checks. Separate queue delay from legitimate time needed to restore memory. |
| VMM transport | Existing safety tick remains 25 ms | Correlate ring and wake delays with lifecycle stages; do not infer causality from similar numbers or disable the tick globally. |
| Guest execution | `run_workload` waits on admission, records intent, calls `run_helper`, validates cleanup and completes intent | Includes helper launch, namespace/root/cgroup setup and cleanup beyond clone3. PID 1 alone does not eliminate these costs. |
| Docker wait | `wait_for_native` exchanges Wait frames until cleanup is complete | A 100 ms long-poll budget is not a mandatory 100 ms sleep. Verify notification latency before replacing it. |
| Memory integration | Growth, independent pressure and idle shrink have isolated evidence | Retain it. Never remove admission or hold RAM fixed to make timing pass. |

Source: [session](../../jetstream/src/native/session.rs),
[Docker owner](../../jetstream/src/native/docker.rs),
[guest lifecycle](../../guest/launch-service/src/fresh_fixture.rs),
[admission identity](../../guest/launch-service/src/core_admission.rs).

The architecture is viable for measurement-driven improvement, but its control
path mixes periodic observation with event-driven approval. That is the first
boundary to investigate. There is no evidence yet that clone3 is the main
remaining cost, or that a wholesale event-loop rewrite is warranted.

## Stage map and instrumentation

```text
host API create/start
  -> guest request accepted / admission pending       G0
  -> host observation request sent                    H0
  <- pending observation received/published           H1
  -> controller sees demand and approves              H2
  -> grant sent                                      H3
  -> guest receives grant / workload unblocked        G1
  -> intent recorded / helper launched                G2
  -> cgroup + namespaces + mounts ready               G3
  -> exec boundary / process exit                     G4/G5
  -> output drained / cgroup and mounts removed       G6
  -> terminal response sent                           G7
  -> host terminal response read                      H4
  -> Docker wait/remove response fully delivered      H5
```

Use boot ID + workload ID + request sequence as correlation keys. Retain the
first stage and every failure. Host and guest use their own monotonic clocks;
never subtract G timestamps from H timestamps. Add a guest-local observation
served timestamp Gobs to measure Gobs-G0 (pending discovery), separately from
H1-H0 (request round trip). Split G1-Gobs from H3-H1 rather than inventing a
cross-machine offset. Record queue depth, admission generation, memory target,
available memory, outstanding grants and whether capacity growth was necessary.

Use bounded in-memory trace records, flushed after each diagnostic window;
no synchronous per-event console/disk logging in timed code. Record overflow
and lost events. Do not trace environment values or payloads. Every traced
sample must join unambiguously; report gaps rather than discard them silently.

## Sequential experiment protocol

1. Freeze current release host, guest, client, image and resource limits. Run
   two untraced controls and two traced boots in alternating order, each with
   ten warmups and 200 sequential API operations. Run CLI separately. Record
   observer overhead; if tracing changes median by more than 5%, reduce it
   and repeat attribution before using its durations quantitatively.
2. For each joined request, report Gobs-G0, G1-Gobs, G2-G1, G3-G2,
   G5-G3, G6-G5, G7-G6 and host H1-H0/H2-H1/H3-H2/H5-H4.
   Separate execution from cleanup, including intent I/O. Report p50/p95/p99,
   distributions and request-level correlation; do not add or subtract
   independently calculated percentiles as a critical-path decomposition.
3. Test discovery cadence as a diagnostic only: current 30 ms versus 5 ms,
   two alternating release pairs at 200 operations plus ten warmups per leg.
   Keep the same policy, 25 ms safety tick, authentication and grant checks.
   Record idle CPU, wake count and memory. A shorter poll is not the proposed
   production solution; this tests sensitivity of pending discovery latency.
4. If pending discovery shrinks with cadence and explains substantial latency,
   add a narrow implementation task for a guest pending-demand notification
   over an authenticated persistent control connection. Notify on empty to
   nonempty demand and reconcile a bounded authoritative snapshot. Keep grants
   keyed by boot/workload/sequence; no cached blanket permission to launch.
5. If discovery is small or the cadence test is negative, keep current behavior
   and choose the largest observed stage: helper/setup, controller scheduling,
   response delivery, output drain, or intent/cleanup I/O. Write one narrowly
   scoped corrective task with a failing regression before editing that stage.
   Do not suppress durability, isolation or verified cleanup as a speed fix.

Run two states separately: already-restored warm capacity and first launch
from converged reduced memory. Also exercise independent pressure during churn.
A pressure restoration cost must not be hidden in warm results or called a
notification bug. Do not run builds concurrently with timing. Keep native
engine and Kiri runs serial and explicitly scoped to private endpoints.

## Conditional architectural correction

```text
Guest ledger: new pending demand
        | bounded authenticated wake notification
Host admission manager: refresh authoritative demand
        | explicit controller wake
Core controller: same capacity / pressure / ownership policy
        | generation-scoped approval notification
Guest authority: validate live request + deadline -> execute
```

One owner mutates the admission ledger. Notifications are hints, never grants.
Handle lost/coalesced wakeups, cancellation before approval, stale boot IDs,
reconnect, duplicate requests and bounded overload. Subscribe then recheck the
predicate to avoid lost wakeups. Preserve a bounded reconciliation fallback;
retain the VMM safety tick. The existing request/response stream cannot be
shared by competing readers: introduce a versioned control capability or a
dedicated authenticated event connection if needed. Do not interleave
unsolicited messages into an unmodified exchange protocol.

Acceptance: no duplicated execution; stale grants rejected; no unapproved
memory use; output and cleanup semantics unchanged. Pressure-driven growth,
active-data checks, idle shrink and backing ownership must pass. Compare
untraced release A/B pairs and reject latency/CPU/memory regressions. A change
is accepted for the isolated candidate only after evidence review.

## Decision gates and reporting

Diagnostic success means identifying the dominant stage with low observer
overhead and a falsifiable intervention, not achieving 5 ms immediately.
If discovery explains only part of the gap, keep the residual visible and
repeat on the next measured stage. Do not repeatedly rerun a failed hypothesis.

Use the existing detailed report format plus the stage table above. Keep
versions, hashes, effective limits, failed samples, per-boot percentiles,
throughput, paired intervals, resource/pressure and cleanup tables. Compare
Kiri only at the same host API/CLI boundaries; its internal guest cleanup
remains unobserved. Native verified cleanup is reported explicitly.

After a real improvement, repeat the two-pair Kiri pilot. Full SPEED-065
qualification still requires five alternating pairs and broader compatibility.
Report below-5-ms API median separately from p99, CLI and parity. No new
performance result exists in this documentation change.

All artifacts and scratch use ExternalSSD; retain raw evidence, remove
transient builds and stop owned processes. No production services or endpoint
changes. This plan precedes additional latency implementation; BuildKit work
may continue independently but is not necessary to diagnose fresh-launch delay.

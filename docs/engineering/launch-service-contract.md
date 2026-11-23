# Conjet native launch service contract

SPEED-003 defines the service used by the isolated fresh launch lane. Later
features require separate capability negotiation and qualification. Conjet's
existing Docker API, engine, images, events, and cleanup remain in the Docker
lane. The native lane has its own explicit endpoint and resource IDs.

## Ownership and transport

The guest supervisor owns container lifecycle from admission through cleanup.
The host client sends requests and observes state. Jetstream transports bytes
and accounts for memory through its existing ownership protocol. VMM device
locks protect device processing and never enclose service handlers, process
creation, filesystem access, or cleanup.

A private host Unix socket connects through a dedicated VSOCK bridge to guest
port 2380. The bridge validates its own address pair. The host socket sits in
the isolated profile's private run directory and is accessible only to its
owner. The guest accepts the expected host CID and verifies the application
handshake. Port 2375 remains the Docker lane and port 2376 remains the memory
lane. A native resource ID is valid only for the native endpoint and boot
generation that issued it.

The trust boundary includes the host runtime, Jetstream, and guest kernel and
supervisor. A fresh per-VM secret is delivered to the supervisor in a
root-only boot artifact under the task-owned profile. The host and supervisor
keep the secret outside workload namespaces and omit it from command lines,
guest console, status, reports, and environment dumps. Clear any temporary
host copy after bootstrap. Authorized host identity is scoped to the selected
runtime profile and VM generation. In a guest fixture the host owner controls
that isolated profile. Workloads have no launch key, launch socket, or
AF_VSOCK access.

### Framing

Use a persistent byte stream. Integers in the fixed header are big endian.

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 4 | ASCII magic `CJLS` |
| 4 | 1 | Header version, initially 1 |
| 5 | 1 | Message kind |
| 6 | 2 | Flags, initially zero |
| 8 | 4 | Payload length, at most 16,384 bytes |
| 12 | 16 | Request ID |

Payloads are UTF-8 JSON objects. Decode into the specific message schema.
Reject unknown fields, duplicate keys, out-of-range numbers, and truncated
frames. Validate the fixed header and size before allocating a payload.
A stream with malformed framing or failed authentication is closed after
an error reply when a valid request ID and frame boundary are available.
Integers are JSON integers with no fractional component. IDs, key proofs
and binary digests have fixed widths. A fresh request uses a nonzero random 128-bit ID. Its reply echoes that ID.
Handshake frames use the initiating hello request ID. Output is pulled
through requests so an idle or slow host cannot produce an unbounded queue.

| Kind | Message | Payload |
|---:|---|---|
| 1 | hello | `versions`, `client_nonce` |
| 2 | challenge | `version`, `guest_nonce`, `boot_id`, `proof` |
| 3 | authenticate | `proof` |
| 4 | hello_ack | `boot_id`, `capabilities`, `limits` |
| 5 | ping | `budget_ms` |
| 6 | pong | `boot_id` |
| 7 | shutdown | `budget_ms` |
| 8 | launch | `boot_id`, `sequence`, `budget_ms`, `spec` |
| 9 | status | `handle`, `budget_ms` |
| 10 | wait | `handle`, `after_revision`, `budget_ms` |
| 11 | cancel | `handle`, `budget_ms` |
| 12 | output | `handle`, `stream`, `offset`, `max_bytes`, `budget_ms` |
| 13 | state | `handle`, `revision`, `phase`, `exec`, `exit`, `cleanup` |
| 14 | output_chunk | `offset`, `next_offset`, `data`, `eof`, `dropped_bytes` |
| 15 | error | `code`, `message`, optional `retry_after_ms` |
| 16 | shutdown_ack | `boot_id`, `state` |

Serialize nonces as lowercase hexadecimal strings of 32 random bytes, a boot
ID as 16 random bytes, and a proof as 32 bytes. Each proof is HMAC-SHA256 with
the 32-byte VM key. Its input is the ASCII string `CJLS1`, the single ASCII
role byte `G` for the guest or `H` for the host, the selected one-byte protocol
version, then one byte for the count of offered versions and those version
bytes in client order. Append the raw hello request ID, client nonce, guest
nonce, and boot ID. Offer one through eight distinct versions. The guest
nonce and boot ID come from the guest CSPRNG.
Check proofs in constant time and bind authentication to the specific
connection. Each party verifies its peer before accepting lifecycle traffic.
The guest selects the highest mutually supported version and reports the
exact limits and capabilities in `hello_ack`.

A `state` reply has a handle with `boot_id` and `workload_id`, an unsigned
revision, one phase from the table below, and `exec` as `pending`,
`confirmed`, `failed`, or `indeterminate`. Its `exit` is null until known,
then either `{"code": integer}` or `{"signal": integer}`. Its `cleanup` is
`pending`, `complete`, or `failed`. A wait timeout identifies whether an
admitted handle already exists. For output, `stream` is `stdout` or `stderr`
and `data` is standard base64. A gap in retained output is accounted for
by `dropped_bytes` and the returned cursor.

The restricted fresh fixture also reports `helper_failed` if the helper did
not confirm cleanup. A successful reconciliation can yield
`helper_failed=true` and `cleanup=complete` in the same terminal state.
The fixture reports bridge teardown independently as `network_cleanup`.
It is `not_applicable` for no-network workloads, `pending` while owned
network resources remain, and `complete` after teardown. An unreconciled
bridge cleanup reports `failed`.

The first implementation advertises `ping`, `shutdown`, and `request_cancel`
for pending waits in its isolated fixture. Guest launch features stay
unadvertised until they pass their implementation gates. A client-side
correlation ID never authorizes a privileged operation by itself. The
transport fixture advertises `fixture_wait` and reserves the all-zero
workload ID with the current boot ID. A wait on this handle becomes a
pending timer without allocating any workload resources.

### Limits, admission, and deadlines

Initial limits are 4 open connections, 8 queued control requests total, one
active long wait per connection, 16 live workload records, and 128 terminal
records. Reserve space for shutdown and cancellation. A saturated request
returns `busy` without making a workload visible. Cap error text at 256 UTF-8
bytes, each output reply at 8,192 decoded bytes, and retained stdout and
stderr at 64 KiB each per workload. The supervisor drains excess output,
increments an explicit dropped-byte counter, and preserves output cursor
semantics. Memory reservations include all per-connection buffers, request
objects, and retained output.

Handshake messages share a two-second monotonic deadline per connection.
A request's `budget_ms` is a relative integer from 1 through 30,000.
The guest starts the deadline on receipt of the complete request. The host
starts its own deadline before sending and treats a host timeout as an
ambiguous result for any committed operation. Clocks stay local. A guest
deadline before admission has no side effects. After admission, deadlines
end the wait for a reply and cleanup remains the supervisor's responsibility.
Server shutdown closes admissions, transitions owned active workloads to
cancellation, and sends `shutdown_ack` only when cleanup succeeds. A failed
drain produces an error and retains recovery ownership.

Use explicit errors `unsupported_version`, `unauthorized`, `malformed`,
`unsupported_option`, `invalid_spec`, `busy`, `deadline_exceeded`,
`id_conflict`, `stale_sequence`, `stale_generation`, `not_found`, and
`cleanup_failed`, and `cancelled`. Request rejection precedes side effects.
For the isolated handshake fixture, `cancel` may contain a `request_id` in
place of a handle and cancels only the matching pending wait on that
connection. The pending wait receives `cancelled`. The cancellation request
receives kind 11 in the reply direction with `request_id` and
`cancelled: true`. Native workload cancellation requires a handle.

## Lifecycle and recovery

A handle contains the boot ID and a random 128-bit native workload ID. Every
state change increments its unsigned 64-bit revision. Wait accepts an
exclusive lower revision bound and can return a terminal state repeatedly.
Status and wait use the same state record.

Wait may request `terminal_output: true`. When cleanup is complete, the
terminal state then carries stdout and stderr chunks, each with its cursor,
EOF and dropped-byte count. The two inline chunks share an 8 KiB decoded
budget within the existing 16 KiB frame bound. A reader resumes each
incomplete stream at its next offset using Output. The capture limit remains
64 KiB per stream. Output delivery and overflow reporting do not move the
guest cleanup boundary.

Output with `follow: true` and a cursor at the captured end waits within
its request budget for data, truncation or terminal EOF. The guest
publishes bounded capture chunks while the workload runs and continues
draining its pipes when there is no reader. Idle followers share the
bounded wait pool with terminal waiters.

The native OCI image control operation uses an authenticated, boot-bound
transfer. One connection owns the upload with a unique transfer ID and
strict successive offsets. The guest admits at most three extra images
with a combined 64 MiB package budget. Chunks contain at most 8 KiB of
decoded data. The guest verifies complete size, package SHA-256 and config
digest before publishing an immutable root. Disconnect discards an
uncommitted transfer. If a commit response is lost, Inspect reports
installed image identity. The guest refuses removal of its boot image or
an image referenced by an admitted workload with unresolved cleanup.

| Phase | Transition owner and rule |
|---|---|
| accepted | Supervisor reserves a bounded record and writes an intent before making resources. |
| preparing | Supervisor owns the immutable lower root, private state and cgroup setup. |
| child_created | Single-threaded execution helper creates the child in its target cgroup. |
| exec_confirmed | The helper reports a verified kernel exec event for this child. |
| running | Helper releases the child after restrictions and exec confirmation. Application readiness is a separate observation. |
| exiting | Supervisor observes exit or initiates cancellation and records which event won. |
| cleaning | Supervisor reaps the init, stops descendants, drains output, and removes owned resources. |
| removed | Owned processes, writable resources and cgroup are gone. Final status is retained within quota. |
| cleanup_failed | Supervisor retains ownership and reports failure while reconciliation continues. |

A failed setup or exec enters cleanup with the specific error and any
observed exit. Record exec confirmation independently of exit code. An
application may exit before it signals readiness. Uncertain exec state is
reported as indeterminate. Successful cancellation names the workload and
means the request was accepted. Cleanup is confirmed by the `removed`
state with `cleanup=complete`. Never count a request reply or early exit
notification as removal.

Every mutating launch request carries the authenticated `boot_id` and an
unsigned 64-bit `sequence`, with
the first launch at 1. The authenticated profile owner assigns strictly
increasing sequence numbers within the boot generation. The service commits
admission and the sequence high-water mark together, before starting any
process. Serialize admission for that owner. Store the complete validated
request body digest with the admitted sequence. An exact retry of a retained
request returns the same handle and current state without creating a child.
A different body with the same retained sequence returns `id_conflict`.
Sequences at or below the high-water mark with no retained record return
`stale_sequence`. A new sequence that cannot be admitted due to quota can
be retried while it remains above the admitted high-water mark. Limits apply
to pending and terminal records. No forgotten retry can create a new process.

Before admission a disconnected request releases its queue space. Once
admission is committed, an ordinary disconnect leaves ownership with the
guest. A reconnect can query or cancel via the original handle or retry the
same launch sequence. Replays across the VM generation are rejected. The
protocol provides at-most-once admission within a generation and makes no
exactly-once promise for workload side effects.

The guest records an intent keyed to the generated ID before creating a
cgroup, filesystem root, or process. Each owned path and cgroup is
deterministic from the intent and lies within its private namespace.
On supervisor restart, rotate the generation and reconcile old intents
before admitting new work. Kill and reap only owned workload cgroups.
Remove mounts and mutable storage in dependency order. Retain cleanup
failures for retry with bounded backoff and reject new admissions if the
service cannot isolate recovery from fresh work. Never replay an old launch
during restart. On VM loss all prior handles become stale and the host
returns ambiguity for work whose outcome was not observed.

## Fresh ARM64 support

The native workload specification is a closed subset of OCI. Its v1 object contains
`image_digest`, `argv`, `env`, `cwd`, `uid`, `gid`, `network`, and `limits`.
The digest is `sha256:` followed by 64 lowercase hexadecimal digits. `env`
is an ordered array of distinct `KEY=value` strings. `network` is `none`.
`limits` includes integer `memory_bytes`, `pids`, and `cpu_millicores`. The
service advertises the allowed ranges and rejects values outside them.
Translate supported fields into the native request only after validation. Resolve
artifacts before allocating workload resources. Discover host kernel,
cgroup, namespace, and seccomp support at startup and advertise fresh
launch only when the complete minimum contract is available.

| Area | Supported initially |
|---|---|
| Image | Native Linux ARM64, exact OCI digest for an image already verified and unpacked into the guest's immutable store. |
| Process | Absolute executable and working directory within the container root. Up to 32 argv entries and 32 explicit environment variables, each at most 1,024 bytes with no NUL and at most 8 KiB combined. |
| User | Explicit numeric UID and GID 65532 in the container with an isolated user namespace and a reserved guest mapping. No supplementary groups. |
| Root and mounts | Private writable overlay over a pinned read-only lower root. PID-scoped read-only procfs and fixed private /dev, /run and /tmp. Guest root changes before executing user code. |
| Network | Private network namespace with no attachment. No host or guest network publication. |
| Resources | Mandatory positive memory, pids, and CPU bounds clamped by the negotiated profile. No implicit unbounded resource class. |
| Security | Private mount, PID, network, IPC, UTS, cgroup, and user namespaces. Drop all workload capabilities, set no-new-privileges, use a pinned ARM64 seccomp policy, and deny privilege transitions. |
| I/O | Closed stdin, separate bounded stdout and stderr with cursor-based reads. |
| Lifecycle | Fresh execution, status, wait, cancel, and cleanup. |

Reject unrecognized OCI fields and unsupported options before resource
creation, including additional mounts, devices, hooks, extra capabilities,
arbitrary seccomp or namespace sharing, TTY, privileged modes, root user,
emulation, host paths, secrets, port publishing and restart policies.
Resolve executable and root paths within trusted directory descriptors with
beneath and symlink protections appropriate to the operation. Treat
a writable image or unsupported mount feature as a validation error.

### Execution and cleanup

Only the dedicated single-threaded helper creates workload children. It
precomputes bounded arguments and descriptors. Use `clone3` with
`CLONE_INTO_CGROUP` and `CLONE_PIDFD` to bind cgroup placement and identity.
The child waits at a bounded authorization barrier while the parent sets
namespace mappings and validates parent-side setup. The helper uses a minimal
syscall-oriented child path to configure the namespace, switch root, set
credentials, clear capabilities, set resource limits, and install seccomp.
Close inherited descriptors except explicit stdio and the execution
handshake. Verify OS return values, terminate on any failed restriction,
and keep unrestricted user code outside this path. A small namespace init
owns descendant reaping and signal forwarding. It delegates workload
creation to the synchronous single-threaded path.

Account workloads in a delegated cgroup v2 subtree separate from Docker.

```text
conjet-native/
  supervisor/
  workloads/
    active/<workload-id>/
    prepared/<slot-id>/     reserved for the prepared capability
```

Set `memory.max`, `pids.max`, and `cpu.max` before releasing a child. Active
accounting begins with resource reservation, includes preparing and cleaning
work, and ends only after confirmed teardown. The host's existing memory
backing release rules continue to depend on the guest ownership transition.
Prepared slots, once enabled, use a distinct reserve and evict before active
work is pressured.

Observe the actual exec event in the single-threaded helper. The initial
restricted fixture may use a kernel exec stop like the SPEED-001 diagnostic
with its overhead reported. Close-on-exec pipe EOF by itself is ambiguous
when a process can die before exec, so it cannot establish exec success.
Use a separate opt-in readiness channel whose producer runs after exec.

Use a pidfd for the init identity and signals. Cancellation forwards a
bounded grace signal, then uses `cgroup.kill` when needed for descendants.
Wait for the init and for the cgroup's populated state to clear. Release
mounts and mutable disk state before removing the owned cgroup and publishing
cleanup completion. Keep failure evidence and continue bounded recovery
when any step fails; never mark the workload removed after a partial cleanup.

### Prepared slots

Only the isolated ARM64 fixture advertises `prepared_arm64_fixture`.
Opcode 17 prepares using the same bounded request as fresh launch and
shares its generation and sequence ledger. Opcode 18 claims with
`handle`, `spec`, and `budget_ms`. The authenticated profile owner,
boot ID, random per-slot workload ID, and digest of the full immutable
specification identify the slot.

The fixture owns at most one fresh or prepared workload, has no
preparation queue, and caps the prepared cgroup at 32 MiB. It stages
the private root inputs, creates the private namespaces and cgroup,
mounts the private root, and installs limits and restricted credentials.
The trusted child then stops under its owned tracer. Seccomp installation
and exec follow a successful claim. The supervisor serializes the
READY-to-CLAIMED transition before writing the release byte.
Exact prepare retries keep the same handle. Consumed slots cannot return
to ready, and a disconnected claimant can query the original handle.

An unclaimed slot accepts claims for at most five seconds from admission.
The helper also enforces a five-second ready timeout so expiry disposes
of the slot without a client. Cancellation closes the execution path of
an unclaimed slot, and terminal state reports verified cleanup. Fresh
fallback is an explicit new request after confirmed non-execution.
An indeterminate claim must be resolved against the original handle.
Measure preparation, claims, misses, expiry, and refill separately.

The isolated native memory fixture uses opcode 19. Its authenticated
request carries `boot_id`, `budget_ms`, and optional `pressure`. The
snapshot reports active and prepared ownership separately, with cgroup
charge, population and sample validity. A claimed slot counts as active
before its release byte is sent. Its existing cgroup retains the charge
through teardown. An owned scope with missing samples remains accounted
for, and cleanup failure retains ownership.

The pressure input pauses preparation and evicts only unclaimed slots.
A refill requires clearing pressure and a new explicit prepare request.
Linux `MemAvailable` below the experimental 64 MiB floor or an unavailable
reading blocks preparation and claims. Only a parked helper rechecks the
floor while waiting, using blocked waits bounded by its five-second lease.
The final release check also verifies the floor.
Jetstream excludes its Docker-only idle controller from the isolated
native mode until a qualified unified policy exists. Guest-reported
ownership transitions continue to govern backing release.

## References

- Linux creation and cgroup placement. [clone3 and CLONE_INTO_CGROUP](https://man7.org/linux/man-pages/man2/clone.2.html)
- Process identity and signaling. [pidfd_open](https://man7.org/linux/man-pages/man2/pidfd_open.2.html)
- Enforcement, populated state, and whole-cgroup termination. [Linux cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)
- Existing engine boundaries. [Speed engineering plan](speed-engineering-plan.md) · [Direct OCI loader](../../Sources/ConjetCore/ConjetContainerRuntime.swift) · [Existing VSOCK framing](../../Sources/ConjetCore/ConjetBinaryFrame.swift)


## Experimental product profile

`conjet native --experimental serve` owns a private Jetstream VM in its
foreground process. Its Unix socket is `native-launch.sock` in the printed
session directory. Verify its peer PID against the session identity and
authenticate with the per-session 32-byte key. The negotiated capability
is `native_static_arm64_v1`. Product sessions expose no Docker endpoint
or network device.

The profile accepts one SHA-256-pinned static ARM64 Linux executable per
VM. Specify its digest as `sha256:<hex>`, argv as `["/bin/probe"]`,
an empty environment, working directory `/work`, UID and GID 65532,
network `none`, 16 MiB, four PIDs, and 500 millicores. A product Launch
or Prepare requires a fresh random lowercase 128-bit `operation_id`
alongside the monotonic sequence. Exact replays retain both values;
a different operation using the same sequence conflicts. CLI commands
own a nonblocking local admission lock through terminal state and
output collection. API clients that mix launches with CLI clients must
hold the session's `admission.lock` while admitting a request and until
they read its retained output. Observe or cancel with a separate connection.

Kind 20, Inspect, takes `{"budget_ms":1000}` and replies as kind 20 with
`boot_id`, `image_digest`, `last_sequence`, and the current or last
`workload` (or null). Kind 19, Memory, takes `boot_id`, `budget_ms`,
and `pressure` (null reads, true evicts unused preparation and pauses
it, false clears the explicit signal). Claim tokens are confined to
their authenticated boot generation. Run and claim report verified
cleanup before success and never retry an indeterminate submission.
The guest can retain an admitted workload after client disconnect. It
remains cancellable and has a 30-second execution ceiling. A subsequent
admission can replace the last terminal record.

# Conjet v2.1.0

Jetstream can now return guest-authorized free memory to macOS through
synchronous backing release, including while containers remain running.

- Restore reported memory mappings before acknowledging the guest, and return
  complete balloon-owned host pages before the full balloon target converges.
- Keep the pressure watchdog active during partial capacity expansion.
- Forward memory-profile idle targets, idle dwell, and service shrink steps from
  Swift orchestration to the Rust VMM, preserving diagnostic overrides.
- Add ownership-ledger checks and reusable native Docker memory correctness
  fixtures, validated alongside the chum-mem PostgreSQL/API/worker/web stack.

Use with [Conjet Core v1.3.0](https://github.com/omega13-engr/conjet/releases/tag/conjet-core-v1.3.0)
for the patched reporting scheduler and current reclaim worker. Existing profiles
can fetch the new guest assets with `conjet update`; that command restarts the
active runtime unless its restart behavior is explicitly overridden.

## Validation and limits

Isolated Linux/HVF checks and Compose E2E verified physical RSS return, live
canaries, demand-zero reuse, database checksums, and restart persistence. See
[the detailed report](https://github.com/omega13-engr/conjet/blob/conjet-v2.1.0/docs/jetstream-memory-e2e.md).

- The idle-capacity check exceeded 90 seconds under the existing zram safeguard
  before later converging to 512 MiB; RSS had already returned.
- Local QA needed a temporary VSOCK proxy for direct guest TCP egress. The normal
  internet, published-port, and host-sharing paths remain separate validation work.
- No latency benchmark, power measurement, or OrbStack comparison was run.
  The 25 ms reporting setting is not an end-to-end RSS deadline.
- This app release uses ad-hoc signing and is not notarized, following the
  repository's existing distribution mode.

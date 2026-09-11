# Conjet Core Jetstream Assets v1.3.0

This release supplies the guest kernel and Docker rootfs appliance for Conjet
v2.1.0's dynamic-memory improvements.

- Patch the pinned Linux 6.12.86 reporter with a bounded 10–2000 ms reporting-delay
  parameter. Jetstream v2.1.0 selects 25 ms unless explicitly overridden.
- Add a root-only reporting trigger that coalesces one per-CPU free-page-cache
  drain after scoped reclaim; ordinary allocator reports do not drain CPU caches.
- Make generic reclaim skip populated or uncertain scopes, recheck between
  chunks, enforce aggregate sibling budgets, and protect active daemon descendants.
- Kick reporting once after successful reclaim completion or partial progress,
  with compatibility fallback for kernels lacking the optional trigger.

The release includes the ARM64 4 KiB-page kernel and the Docker rootfs appliance,
each with metadata and SHA-512 checksums. Use with
[Conjet v2.1.0](https://github.com/omega13-engr/conjet/releases/tag/conjet-v2.1.0)
for the complete host/guest release path.

Existing profiles can fetch these assets with `conjet update`, which preserves
the profile data disk and normally restarts the runtime. The reporting interval
is a scheduling setting, not a guaranteed RSS-return deadline. Existing zram and
pressure safeguards can delay capacity shrink. See the
[E2E report](https://github.com/omega13-engr/conjet/blob/conjet-core-v1.3.0/docs/jetstream-memory-e2e.md)
for the local network workaround and validation limits. No performance or energy
comparison was performed.

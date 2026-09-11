# Docker dynamic-memory correctness fixtures

These fixtures exercise the immediate-release implementation in a **disposable
Jetstream VM**. They can run while the real chum-mem Compose services are active.
Use fresh VM disks and an isolated Docker socket; the runner never boots or stops
the installed Conjet runtime and never changes the user's Docker context.

The two containers each retain a 64 MiB canary. One also allocates and dirties
512 MiB using anonymous `mmap`, verifies every byte, and releases it with `munmap`.
Three cycles verify host RSS return, the untouched canary in the other container,
and demand-zero contents on subsequent allocations before userspace writes them.
The native fixture avoids runtime GC and allocator-retention ambiguity.

The Dockerfile's `build-workload` target writes, syncs, and reads a 512 MiB file
while holding a separate 512 MiB anonymous allocation. Both are verified and
released before the build completes. A six-second hold makes the allocation
observable to the coarse correctness sampler. A unique build argument reruns
this stage while preserving compiler/dependency cache layers.

The runner checks the ownership ledger throughout, requires an observable
256 MiB RSS reduction after the known allocation and after the build, verifies
the live canaries, then restarts the fixtures and checks health and OOM state.
The 60-second failure timeout is a correctness bound, **not** a claimed release
latency. The trace records RSS and physical footprint separately. It produces no
benchmark percentiles, throughput, energy, or OrbStack comparison. Performance,
warm-cache cost, and power efficiency still need separate measurements.

From the repository root, with a QA VM already booted using the current VMM,
patched kernel, and guest reclaim worker:

```sh
python3 build-support/run-docker-memory-e2e.py \
  --docker-socket "$qa_root/run/docker.sock" \
  --memory-control-socket "$qa_root/run/control.sock" \
  --qa-root "$qa_root/docker-memory-e2e" \
  --docker-config "$qa_root/docker-config"
```

`--docker-config` is optional. When omitted, the runner creates an isolated
configuration, including installed Homebrew Docker CLI plugin locations when
available. Use the option for an existing **QA** configuration that supplies
registry/proxy settings. The explicitly selected Unix sockets must exist; there
is no fallback to a default Docker daemon. At least 2 GiB configured guest RAM is
required; allow additional room for chum-mem's database, API, worker, and web.

The runner uses a unique Compose project and tears down only its two fixture
containers. JSONL telemetry, command logs, and return snapshots remain under the
specified QA directory for review. Stop the disposable VM and remove its disks,
helper processes, and QA directory after archiving the desired evidence.

For chum-mem E2E coverage, also verify `/ready`, session ingestion and deduplication,
worker job completion, repository graph/search, the web dashboard, and database
checksums across release and service restarts. Copy the checkout into the QA root,
use fresh PostgreSQL/TurboVec volumes, and use synthetic sessions. Bake the SQL
migrations into the QA PostgreSQL image if the raw VMM has no host directory
sharing. Keep any network workaround explicit in the results; it does not
validate the normal networking path.

The fixture's fast native regression check can run without a VM:

```sh
python3 build-support/docker-memory-e2e/test-fixture.py "$qa_root/fixture-native"
```

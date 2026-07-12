# Runtime Progress

Conjet has one VM backend: Jetstream, the Rust VMM built directly on macOS
Hypervisor.framework (HVF). The release runtime no longer includes its legacy
backend.

Current implemented path:

1. `conjet start` resolves the latest compatible Conjet Core root disk and
   matching direct ARM64 Linux kernel, verifies checksums, and imports them.
2. `conjetd` starts Jetstream with the direct kernel, root disk, persistent
   data disk, virtio-net, VSOCK, and virtio-balloon/page-reporting devices.
3. Conjet Core starts Docker and exposes its API through the guest VSOCK
   control bridge to the host Unix socket.
4. Docker image, container, BuildKit, and volume state stays on the persistent
   Linux data disk.
5. Jetstream owns dynamic-memory policy and reclaims only complete native host
   granules authorized by balloon ownership or page-reporting ranges.
6. The ARM64 guest kernel uses 4 KiB pages for x86-64 user-mode compatibility;
   Jetstream still tracks all 4 KiB PFNs composing a native host granule before
   reclaiming it.
7. Conjet Core registers a pinned static QEMU linux-user x86-64 interpreter
   with `binfmt_misc` flags `POF`. Translation starts only for x86-64 ELF
   processes; ARM64 executables remain native.
8. A small downstream QEMU patch selects stable CoreCLR JIT defaults for
   translated .NET workloads while honoring explicit container overrides.

Validation gates for the current runtime are:

- direct HVF boot with the release kernel and rootfs artifacts;
- native ARM64 and `linux/amd64` Docker execution;
- Node.js, GCC/Clang, Java, Python, and .NET/MSBuild amd64 build workloads;
- the CodeChum interactive-checkers Compose build;
- native exec benchmarking with x86 binfmt enabled and disabled;
- dynamic-memory controller, balloon feature, and memory-ledger checks with no
  unauthorized, pinned, or guest-owned reclaim.

Generated rootfs metadata records the x86 emulation engine, version, and binfmt
flags. `/etc/conjet/release` records the same information inside the guest.

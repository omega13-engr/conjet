# Guest Kernel

Kernel work starts after the Virtualization.framework boot path is proven. The
first requirement is a Linux kernel with VirtioFS, virtio-blk, virtio-net,
vsock, inotify/fanotify, and cgroup support.

## Conjet Direct-Kernel Lane

The direct-kernel VM path must not depend on a distro installer kernel. Build an
upstream Linux ARM64 `Image` with Conjet's required virtual hardware enabled
built-in:

- PL011 serial console and GICv3 for early boot diagnostics.
- virtio-mmio transport, virtio-blk root/data/swap, virtio-net, virtio-rng,
  virtio-vsock, and virtio-balloon with free-page reporting.
- devtmpfs, initramfs gzip, ext4, overlayfs, tmpfs, namespaces, cgroup v2, PSI,
  compaction, zram, netfilter, and bridge support for Docker/container
  workloads.

Conjet's HVF memory model uses guest telemetry for policy, virtio-balloon
target changes for hard pressure, and virtio-balloon free-page reporting for
automatic page-level reclaim below the guest-visible memory cap. The hard-drop
path additionally lets the guest offline Linux-removable memory blocks and lets
the host decommit the exact offlined guest-physical spans, which gives macOS a
real mapping/accounting drop instead of only a free-page hint. The legacy manual
pulse reclaim path is fallback only. Reclaim-capable kernels must keep
`CONFIG_VIRTIO_BALLOON`, `CONFIG_PAGE_REPORTING`,
`CONFIG_BALLOON_COMPACTION`, `CONFIG_COMPACTION`, `CONFIG_MEMORY_HOTPLUG`,
`CONFIG_MEMORY_HOTREMOVE`, `CONFIG_PSI`, `CONFIG_SWAP`, `CONFIG_ZSMALLOC`, and
`CONFIG_ZRAM` enabled; the Docker profile also enables `CONFIG_ZRAM_WRITEBACK`.

The reproducible builder is:

```sh
guest/kernel/scripts/build-linux.sh
```

Before running a full build, check the builder host and LLVM toolchain:

```sh
guest/kernel/scripts/build-linux.sh --check-tools
```

It downloads the configured upstream kernel tarball from `cdn.kernel.org`,
verifies the tarball SHA-256 against `sha256sums.asc` or `KERNEL_SHA256`,
seeds a Conjet-minimal ARM64 `allnoconfig` build with the selected profile
fragment, validates that the resolved `.config` kept every required built-in,
then emits:

```text
guest/kernel/dist/linux-<version>-conjet-arm64/Image
guest/kernel/dist/linux-<version>-conjet-arm64/.config
guest/kernel/dist/linux-<version>-conjet-arm64/System.map
guest/kernel/dist/linux-<version>-conjet-arm64/vmlinux
guest/kernel/dist/linux-<version>-conjet-arm64/manifest.json
```

Useful overrides:

```sh
KERNEL_VERSION=6.12.86 guest/kernel/scripts/build-linux.sh
KERNEL_PROFILE=fast guest/kernel/scripts/build-linux.sh
KERNEL_BASE_CONFIG=defconfig guest/kernel/scripts/build-linux.sh
OUT_DIR=/tmp/conjet-kernel guest/kernel/scripts/build-linux.sh
MAKE_FLAGS="-j12 LLVM=1" guest/kernel/scripts/build-linux.sh
```

The default `KERNEL_PROFILE=docker` uses `config/conjet-arm64.config`, keeps
PL011 serial diagnostics enabled, and includes the broader Docker appliance
network/storage feature set. `KERNEL_PROFILE=fast` uses
`config/conjet-fast-arm64.config`, emits
`guest/kernel/dist/linux-<version>-conjet-fast-arm64/`, leaves PL011 serial out,
and is intended for the Pulse direct-OCI lane where binary readiness supplies
the T4 milestone. Use the Docker/debug profile for emergency serial-console
boot diagnostics.

Run this in a Linux builder with a normal kernel toolchain. The output `Image`
is the kernel that should be paired with `conjet vm build-initramfs
--conjet-ready-probe` for early guest proofs.

For Phase 9, use the custom network proof initramfs instead of a distro
userspace. The preferred Linux-builder entry point is:

```sh
guest/kernel/scripts/build-phase9-network-proof-assets.sh
```

It runs the kernel builder, runs the static BusyBox builder, builds the
validated network-proof initramfs directly in shell, and writes:

```text
guest/kernel/dist/phase9-network-proof/Image
guest/kernel/dist/phase9-network-proof/kernel-build-manifest.json
guest/kernel/dist/phase9-network-proof/busybox
guest/kernel/dist/phase9-network-proof/conjet-network-proof-initramfs.cpio.gz
guest/kernel/dist/phase9-network-proof/phase9-network-proof-assets.json
```

Before running a full bundle build, check prerequisites:

```sh
guest/kernel/scripts/build-phase9-network-proof-assets.sh --check-tools
```

The bundle build validates its own output before returning. To re-run that
offline validation explicitly:

```sh
guest/kernel/scripts/verify-phase9-network-proof-assets.pl \
  --manifest guest/kernel/dist/phase9-network-proof/phase9-network-proof-assets.json
```

The verifier checks the portable manifest, all SHA-256 values, the uncompressed
ARM64 Linux `Image` header, required kernel config built-ins, the initramfs
network-proof markers, and the static AArch64 BusyBox binary embedded in
`bin/busybox`.

Import the generated bundle into an isolated `CONJET_HOME` before running the
proof. The importer verifies the bundle schema, all SHA-256 values, the direct
ARM64 Linux `Image` header, and the static ARM64 BusyBox embedded in the
network-proof initramfs. When the bundle includes `kernel-build-manifest.json`,
the importer also verifies that the manifest's `imageSha256` matches the bundle
kernel and that the built kernel kept Conjet's required virtio, networking, and
container config options built in:

```sh
CONJET_HOME=/tmp/conjet-qa/home \
  conjet vm import-phase9-network-proof \
  --manifest guest/kernel/dist/phase9-network-proof/phase9-network-proof-assets.json
```

For the Phase 2 signed boot proof, use the host-side harness after a direct
kernel/initramfs exists. It signs the debug CLI with the Hypervisor entitlement,
creates an isolated `CONJET_HOME`, imports only the provided assets, writes a
DTB/boot-plan artifact, runs `boot-attempt`, records production evidence, and
checks Phase 2 readiness without contacting the user's live daemon, VM, Docker
socket, containers, or vmnet state:

```sh
build-support/run-jetstream-boot-proof.sh \
  --kernel guest/kernel/dist/linux-6.12.86-conjet-arm64/Image \
  --build-ready-initrd
```

Use `--preflight-only` first when validating a newly produced bundle on a
developer Mac. It still builds/signs the debug CLI, checks the Hypervisor
entitlement, imports assets into an isolated home, and writes the DTB/boot-plan
artifacts plus `jetstream-boot-proof-summary.json`. With `--build-ready-initrd`,
it also generates `conjet-ready-initramfs.cpio.gz` under the QA root. It does
not start HVF or vmnet:

```sh
build-support/run-jetstream-boot-proof.sh \
  --kernel guest/kernel/dist/linux-6.12.86-conjet-arm64/Image \
  --build-ready-initrd \
  --preflight-only
```

The same harness can consume a generated Phase 9 bundle:

```sh
build-support/run-jetstream-boot-proof.sh \
  --phase9-manifest guest/kernel/dist/phase9-network-proof/phase9-network-proof-assets.json
```

Phase 9 bundle runs require `CONJET_INIT_READY` automatically. For the lower
level `--kernel` path, use `--build-ready-initrd` or pass `--initrd` whenever
using `--require-init-ready`; the harness fails before build/sign/boot work if
init-ready proof is requested without an initramfs source.

The lower-level manual path is to build the pinned static ARM64 BusyBox artifact
first:

```sh
guest/kernel/scripts/build-busybox.sh
```

Before running a full BusyBox build, check the ARM64 Linux cross compiler and
supporting tools:

```sh
guest/kernel/scripts/build-busybox.sh --check-tools
```

The script downloads the configured BusyBox source tarball, verifies the
upstream SHA-256 file, enables the static applets needed by the initramfs, and
emits:

```text
guest/kernel/dist/busybox-<version>-conjet-arm64/busybox
guest/kernel/dist/busybox-<version>-conjet-arm64/.config
guest/kernel/dist/busybox-<version>-conjet-arm64/manifest.json
```

Then build the network-proof initramfs:

```sh
guest/kernel/scripts/build-network-proof-initramfs.sh \
  --busybox guest/kernel/dist/busybox-1.38.0-conjet-arm64/busybox \
  --proof-url http://example.com \
  --guest-service-port 8080 \
  --output conjet-network-proof-initramfs.cpio.gz
```

This image is still intentionally small: BusyBox DHCP configures `eth0`, the
guest probes outbound HTTP, and BusyBox `httpd` exposes a proof marker for
host-side vmnet port-forward checks. The builder rejects placeholder userspace:
the BusyBox binary must be an ELF64 AArch64 Linux executable with no dynamic
interpreter segment, and the Phase 9 preflight re-validates the embedded
`bin/busybox` before any HVF VM work starts. The BusyBox config must include
`udhcpc`, `nslookup`, `wget`, and `httpd` so the guest can prove DHCP, DNS,
outbound TCP, and host forwarded-port reachability from the same initramfs.

After importing the custom kernel/initramfs bundle into an isolated
`CONJET_HOME`, use the combined Phase 9 proof command:

```sh
conjet vm backend phase9-network-proof \
  --output-dir /tmp/conjet-qa/phase9-network \
  --host-port 18080 \
  --guest-port 8080 \
  --require-ready
```

It writes the console log, host forwarded-port response, proof JSON, and
`phase9-evidence.json`. Before booting, it checks that the manifest uses a
direct ARM64 Linux `Image` header and a generated network-proof initramfs; a
plain initramfs, placeholder kernel, or distro installer initrd fails before
HVF VM work starts. The forwarded-port proof also requires the host HTTP
response to contain the same `CONJET_NETWORK_SERVICE_TOKEN` value emitted by
that boot's guest console, so stale response files cannot pass readiness.

The lower-level diagnostic sequence is:

```sh
conjet vm backend boot-attempt \
  --start-vmnet \
  --require-init-ready \
  --timeout-ms 30000 \
  --console-log /tmp/conjet-qa/network-console.log \
  --network-proof-host-port 18080 \
  --network-proof-guest-port 8080 \
  --network-proof-response /tmp/conjet-qa/forwarded-port-response.txt

conjet vm backend network-proof \
  --console-log /tmp/conjet-qa/network-console.log \
  --host-response /tmp/conjet-qa/forwarded-port-response.txt \
  --output-dir /tmp/conjet-qa/proofs \
  --require-ready
```

The command writes `networkOutboundTCP.json` and
`networkForwardedPort.json`. The outbound proof requires both
`CONJET_NETWORK_DNS_RESOLVED` and `CONJET_NETWORK_OUTBOUND_TCP_OK` in the guest
console. The forwarded-port proof requires `CONJET_NETWORK_GUEST_SERVICE_READY`,
`CONJET_NETWORK_SERVICE_TOKEN`, and a matching token in the host-fetched
`CONJET_NETWORK_FORWARDED_PORT_OK` response. Feed those proof files into
`net-smoke` or `readiness --proof-dir` so Phase 9 only passes with concrete
same-boot guest-console and host-fetch artifacts.

The GitHub Actions entry point for reproducible asset generation is
`.github/workflows/jetstream-kernel-assets.yml`. It builds the kernel, BusyBox,
and initramfs on `ubuntu-24.04-arm`, uploads a portable Phase 9 bundle, then
validates `conjet vm import-phase9-network-proof` plus
`conjet vm backend boot-plan` on `macos-15` with an isolated `CONJET_HOME`.
This is an asset-build lane only; it does not start a developer's local Conjet
app, daemon, VM, containers, Docker socket, or vmnet.

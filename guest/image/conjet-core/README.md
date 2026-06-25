# Conjet Core Image

This directory builds the Conjet-owned Linux guest root filesystem. It uses an
Ubuntu rootfs bootstrapped directly inside the privileged build container, turns
it into a Conjet appliance, and pairs it with the Conjet Linux kernel for
Virtualization.framework/HVF boot.

The output is intentionally Conjet-specific:

- Ubuntu rootfs built directly into a partitioned raw disk, with cloud-init
  disabled.
- Raw root disk for direct Conjet Linux kernel boot.
- `conjet-appliance.target` as the default systemd target, avoiding server-style
  multi-user boot units such as gettys, wait-online, package timers, and SSH.
- Docker Engine from Ubuntu packages.
- Docker state mounted from the attached `conjet-data` disk when present. The
  guest formats a blank data disk as a dedicated Docker/build-cache filesystem
  before Docker starts; if no data disk is attached, it falls back to root-disk
  storage.
- Boot diagnostics are installed but not enabled in the default appliance target;
  run them explicitly when debugging so serial diagnostics do not slow normal boot.
- Docker daemon defaults tuned for local container builds: overlay2, BuildKit,
  Docker bridge networking with NAT, local logs, no userland proxy, and bounded
  concurrent transfers.
- Conjet guest VSOCK bridge listening on port `2375`, forwarding Docker API
  traffic to `/var/run/docker.sock`, and proxying published TCP/UDP ports back
  to macOS localhost.
- `conjet-netd`, the compiled guest bridge used by new images for capability
  reporting, guest echo, bridge metrics, binary frame probes, and the next UDP
  fast path. The Python bridge remains installed as fallback.
- `conjet-memd`, a separate guest memory telemetry service on VSOCK port `2376`
  that reports cgroup v2 memory, `/proc/meminfo`, and PSI pressure for dynamic
  host-side balloon control. It also exposes guest-coordinated hard drops where
  Linux-removable memory blocks are offlined before the host decommits their
  backing pages, plus `conjet-reclaimd` for scoped cgroup-v2 `memory.reclaim`
  jobs after Docker/build activity.
- DHCP networkd/netplan fallback for the VZ NAT interface.
- Cloud-init disabled by default to avoid first-boot datasource waits.
- `vsock`, `virtio_balloon`, `virtiofs`, and `zram` modules requested on boot.
- `conjet-init-ready.service`, which waits for the Docker VSOCK bridge, sends
  binary `CONTROL_READY` and `PROCESS_STARTED` records to the host readiness
  VSOCK port, and still writes `CONJET_INIT_READY` to the serial console for
  debug and legacy Jetstream/HVF managed start readiness.

## Build

The builder needs Docker with privileged containers. On Apple Silicon:

```sh
cd guest/image/conjet-core
make image
```

Useful overrides:

```sh
make image ROOT_DISK_GB=20
make image OS_ARCH=x86_64
make image RUNTIME=none
```

The main artifact is written to:

```text
guest/image/conjet-core/dist/out/conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz
```

Import it into Conjet:

```sh
swift build
.build/debug/conjet vm fetch-conjet-core \
  --image guest/image/conjet-core/dist/out/conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz \
  --force
```

For Jetstream/HVF, pair the same root disk with a Conjet ARM64 Linux `Image`.
This is the production path; the Ubuntu label describes the rootfs seed, not the
kernel:

```sh
.build/debug/conjet vm fetch-conjet-core \
  --image guest/image/conjet-core/dist/out/conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz \
  --kernel guest/kernel/dist/linux-6.12.86-conjet-arm64/Image \
  --force
```

After signing the debug binaries, start the VM and run a Docker image:

```sh
build-support/sign-debug.sh
.build/debug/conjet vm start
.build/debug/conjet run hello-world
```

For normal users, this manual import should not be necessary. The GitHub
workflow at `.github/workflows/conjet-core-image.yml` publishes these artifacts
as `conjet-core-vX.Y.Z` releases, and `conjet start` downloads the newest
matching image automatically when no VM is configured. HVF profiles also require
the matching `conjet-linux-*-aarch64-Image` release asset; if it is absent,
Conjet fails with an explicit kernel-asset error instead of importing an EFI
disk that HVF cannot boot.

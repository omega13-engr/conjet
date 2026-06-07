# Conjet Core Image

This directory builds the Conjet-owned Ubuntu minimal guest image. It follows
the same high-level pattern as colima-core: fetch an upstream Ubuntu minimal
cloud image, mutate it inside a privileged Docker build container, then emit a
compressed raw disk image.

The output is intentionally Conjet-specific:

- Ubuntu minimal cloud image base.
- EFI/GPT raw disk suitable for `VZEFIBootLoader`.
- Docker Engine from Ubuntu packages.
- `neofetch` for quick guest identity and environment inspection.
- Conjet guest VSOCK bridge listening on port `2375`, forwarding Docker API
  traffic to `/var/run/docker.sock`, and proxying published TCP/UDP ports back
  to macOS localhost.
- `conjet-netd`, the compiled guest bridge used by new images for capability
  reporting, guest echo, bridge metrics, binary frame probes, and the next UDP
  fast path. The Python bridge remains installed as fallback.
- DHCP netplan fallback for the VZ NAT interface.
- Cloud-init disabled by default to avoid first-boot datasource waits.
- `vsock` and `virtio_vsock` modules requested on boot.

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
guest/image/conjet-core/dist/out/conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz
```

Import it into Conjet:

```sh
swift build
.build/debug/conjet vm fetch-conjet-core \
  --image guest/image/conjet-core/dist/out/conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz \
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
matching image automatically when no VM is configured.

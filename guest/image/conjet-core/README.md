# Conjet Core Image

This directory builds the Conjet-owned Ubuntu minimal guest image. It follows
the same high-level pattern as colima-core: fetch an upstream Ubuntu minimal
cloud image, mutate it inside a privileged Docker build container, then emit a
compressed raw disk image.

The output is intentionally Conjet-specific:

- Ubuntu minimal cloud image base.
- EFI/GPT raw disk suitable for `VZEFIBootLoader`.
- Docker Engine from Ubuntu packages.
- Conjet guest VSOCK bridge listening on port `2375` and forwarding to
  `/var/run/docker.sock`.
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
as releases, and `conjet start` downloads the latest matching image
automatically when no VM is configured.

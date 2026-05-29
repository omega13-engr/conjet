# Guest Image

This directory holds build recipes for Conjet guest images.

The first Conjet-owned image recipe is `conjet-core/`. It follows the
colima-core-style model: download Ubuntu minimal cloud image, mutate it in a
privileged Docker builder, and emit a compressed raw EFI disk artifact for
Conjet only. The baked image includes Docker, the Conjet guest VSOCK bridge,
netplan DHCP for the VZ NAT interface, and vsock module loading.

Normal users should use:

```sh
conjet start
```

On first run, that command downloads the latest matching Conjet-core image from
GitHub releases and imports it automatically.

```sh
cd guest/image/conjet-core
make image
cd ../../..
.build/debug/conjet vm fetch-conjet-core \
  --image guest/image/conjet-core/dist/out/conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz \
  --force
```

The direct-kernel image path remains useful once Conjet has its own static
Linux guest agent and init system:

Current host support can create the initramfs wrapper once a static Linux
`/init` exists:

```sh
conjet vm build-initramfs --init /path/to/linux-arm64-static-init --output initramfs.cpio.gz
```

That future direct-kernel recipe should combine the initramfs with a direct
ARM64 Linux `Image`/`vmlinux` kernel, then add containerd, runc, BuildKit, and
the Docker socket bridge.

There is also a distro-image lane for faster runtime bring-up:

```sh
conjet vm fetch-ubuntu-cloud --release noble --cloud-init-docker --force
```

That lane boots through `VZEFIBootLoader`, attaches the cloud-init seed ISO,
converts Ubuntu's QCOW2-backed `.img` to raw, expands the boot disk for Docker,
and has been verified with `conjet run hello-world`. It remains the shortest
path to a real guest Docker daemon before the custom minimal image is ready.

# Guest Image

This directory will hold build recipes for the minimal Linux guest image,
including containerd, BuildKit, runc, Conjet agent binaries, and kernel/module
requirements.

Current host support can create the initramfs wrapper once a static Linux
`/init` exists:

```sh
conjet vm build-initramfs --init /path/to/linux-arm64-static-init --output initramfs.cpio.gz
```

The next image recipe should combine that initramfs with a direct ARM64 Linux
`Image`/`vmlinux` kernel, then add containerd, runc, BuildKit, and the Docker
socket bridge.

There is also a distro-image lane for faster runtime bring-up:

```sh
conjet vm fetch-ubuntu-cloud --release noble --cloud-init-docker --force
```

That lane boots through `VZEFIBootLoader`, attaches the cloud-init seed ISO,
converts Ubuntu's QCOW2-backed `.img` to raw, expands the boot disk for Docker,
and has been verified with `conjet run hello-world`. It remains the shortest
path to a real guest Docker daemon before the custom minimal image is ready.

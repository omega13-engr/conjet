# Conjet

Conjet is a macOS container runtime prototype focused on light idle behavior,
low power usage, and faster filesystem-heavy development workflows.

This repository currently implements the first real container-runtime slice from
`CONJET_IMPLEMENTATION_PLAN.md`:

- SwiftPM package with `conjet` and `conjetd`.
- Host capability and Virtualization.framework probing.
- User-scoped config at `~/.conjet/config.toml`, or `CONJET_HOME` for isolated runs.
- Unix-domain control socket at `~/.conjet/run/conjetd.sock`.
- Benchmark JSON and Markdown result output.
- Initial ConjetFS path placement classifier.
- Initial energy governor state and resource policy model.
- VZ VM asset management, raw root/data disk creation, serial log path, NAT/vsock/bootstrap-share configuration, and daemon VM lifecycle commands.
- VM boot artifact classification, with both direct-kernel and EFI-disk boot
  lanes represented in the manifest.
- EFI cloud/distro disk import, including qcow2-to-raw conversion when
  `qemu-img` is available.
- First-class Ubuntu Noble ARM64 cloud image fetch/import path for the
  QCOW2-backed `.img` published by Ubuntu, including raw boot disk expansion
  for Docker-capable cloud-init boots.
- Cloud-init NoCloud seed ISO generation for bootstrapping Docker inside an
  imported distro image, with serial/bootstrap-share diagnostics.
- Host Docker socket bridge that listens at `~/.conjet/run/docker.sock` after
  VM start and forwards Docker API byte streams to the guest over VSOCK port
  2375.
- Deterministic initramfs builder for packaging a supplied static Linux `/init`
  binary into a gzip-compressed `newc` archive.
- Conjet-owned Docker socket target for `conjet run`; it intentionally does not fall back to Docker Desktop, Colima, or OrbStack.

## Build

```sh
swift build
swift test
```

Virtualization.framework requires a signed binary with the virtualization
entitlement. For local debug builds:

```sh
swift build
build-support/sign-debug.sh
```

## Run

```sh
swift run conjet doctor --json
swift run conjet bench profile --json
swift run conjet bench small-files --files 10000 --bytes 128 --markdown
swift run conjet sync classify node_modules/react/index.js
swift run conjet power policy warm-idle
```

For daemon and VM lifecycle testing, build first so `conjet` can find sibling
`conjetd`:

```sh
swift build
build-support/sign-debug.sh
export CONJET_HOME="$(mktemp -d /tmp/conjet.XXXXXX)"
.build/debug/conjet vm fetch-fedora --release 43
.build/debug/conjet vm validate  # reports current boot incompatibility for fetched netboot kernels
.build/debug/conjet vm build-initramfs --init /path/to/linux-arm64-static-init
.build/debug/conjet vm fetch-ubuntu-cloud --release noble --cloud-init-docker --force
.build/debug/conjet vm import-efi-disk --image /path/to/cloud-image.qcow2 --cloud-init-docker
```

`fetch-fedora` and `fetch-alpine` currently fetch public netboot assets for
inspection. On Apple Silicon those kernels are compressed ARM64 EFI zboot
artifacts, so `vm validate` reports that they are not runnable by Conjet's
current `VZLinuxBootLoader` path. Use `conjet vm init --kernel PATH` with a
direct Linux `Image`/`vmlinux` kernel and an initramfs from
`conjet vm build-initramfs` for actual VM start experiments.

For distro/cloud image experiments, import an EFI-bootable ARM64 image:

```sh
.build/debug/conjet vm fetch-ubuntu-cloud --release noble --cloud-init-docker --force
.build/debug/conjet vm validate
.build/debug/conjet vm start
.build/debug/conjet run hello-world
```

This path downloads Ubuntu's ARM64 UEFI/GPT cloud image, inspects its real disk
format with `qemu-img info`, converts it to the raw disk expected by
Virtualization.framework, expands the boot disk to 16 GiB by default, and
attaches a NoCloud seed ISO. The seed installs Docker and a guest
VSOCK-to-Docker bridge. After VM start, Conjet exposes
`~/.conjet/run/docker.sock` and forwards Docker API traffic to guest VSOCK port
2375.

## Current Boundary

Conjet can now run a Docker image through a real Virtualization.framework
Ubuntu guest. On 2026-05-29, a signed debug build downloaded Ubuntu Noble's
ARM64 cloud image, converted and expanded it, booted it with cloud-init,
started guest Docker, exposed `~/.conjet/run/docker.sock`, and successfully ran
`conjet run hello-world`.

The custom minimal Conjet guest image is still future work. Smoke testing
downloaded Alpine and Fedora boot assets, and Conjet classifies those public netboot
`vmlinuz` artifacts as compressed ARM64 EFI zboot kernels before they reach
Virtualization.framework.

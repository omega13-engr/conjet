# Runtime Progress

Current implemented runtime path:

1. `conjet vm fetch-fedora` downloads Fedora PXE `vmlinuz` and `initrd.img`.
2. `conjet vm fetch-alpine` downloads Alpine netboot `vmlinuz-virt`,
   `initramfs-virt`, and `modloop-virt`.
3. `VMImageStore` creates sparse raw root/data disks and records the boot
   artifact kind in the VM manifest.
4. `conjet vm validate` rejects compressed ARM64 EFI zboot assets before they
   reach `VZLinuxBootLoader`.
5. `conjet vm build-initramfs --init PATH` packages a supplied static Linux
   `/init` binary into a gzip-compressed `newc` initramfs.
6. `conjet vm import-efi-disk --image PATH` imports a full EFI-bootable
   distro/cloud image as a raw VZ boot disk and records an EFI variable store.
7. `conjet vm fetch-ubuntu-cloud --release noble --cloud-init-docker` downloads
   Ubuntu's ARM64 cloud image, probes its actual disk format, converts it to raw
   when needed, expands the raw boot disk to 16 GiB by default, and creates an
   EFI-disk manifest.
8. `conjet vm build-cloud-init-seed` creates a NoCloud `cidata` ISO whose
   payload installs and starts Docker inside the guest, emits serial markers,
   and copies bootstrap logs into the host bootstrap share when VirtioFS mounts.
9. The cloud-init payload installs a guest VSOCK bridge from port 2375 to
   `/var/run/docker.sock`.
10. `conjetd` can validate assets and attempt VZ VM start/stop through the
   control socket.
11. After VM start, `conjetd` owns `~/.conjet/run/docker.sock` and forwards
    Docker API byte streams to guest VSOCK port 2375.
12. `conjet run IMAGE [CMD...]` targets `~/.conjet/run/docker.sock` only.

Observed smoke-test results on 2026-05-29:

- Unsigned debug `conjetd` fails VZ validation due missing
  `com.apple.security.virtualization`.
- `build-support/sign-debug.sh` fixes that validation failure.
- Adding `com.apple.vm.networking` to an ad-hoc debug signature causes macOS to
  kill the process immediately, so it is not part of the debug path.
- Alpine latest-stable aarch64 `vmlinuz-virt` and Fedora 43 aarch64
  `pxeboot/vmlinuz` both identify as compressed ARM64 EFI zboot applications.
- Conjet now classifies those assets as
  `linux-arm64-compressed-efi-zboot` and rejects them before VM start, instead
  of surfacing an opaque `VZErrorDomain Code=1` from Virtualization.framework.
- The initramfs builder produces a gzip-valid archive from a supplied static
  `/init`; this is host-side packaging only, not a container runtime guest yet.
- The EFI import path is validated with local raw-image smoke inputs and unit
  tests, including a QCOW2 image with an `.img` suffix and explicit boot-disk
  expansion.
- The cloud-init seed builder produces an ISO containing Docker bootstrap
  commands, serial/bootstrap-share diagnostics, and a Python VSOCK-to-Docker
  bridge.
- The host Docker socket bridge is unit-tested for socket ownership and
  no-guest HTTP 503 behavior.
- A signed debug build fetched Ubuntu Noble ARM64 from
  `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img`
  on 2026-05-29, converted it from QCOW2 to raw, expanded the raw boot disk to
  16 GiB, booted it with `VZEFIBootLoader`, installed Docker via cloud-init, and
  exposed guest Docker Engine 29.1.3 through `~/.conjet/run/docker.sock`.
- `CONJET_HOME=/tmp/conjet-ubuntu.rG7eOg .build/debug/conjet run hello-world --json`
  completed successfully through the Conjet socket with exit code 0.

Next required work:

- Promote the Ubuntu cloud-image lane from smoke path to reusable local runtime
  setup, including lifecycle cleanup and image-cache management.
- Replace the Ubuntu bootstrap path with a smaller custom Conjet guest image
  containing containerd, runc, BuildKit, and the guest bridge.

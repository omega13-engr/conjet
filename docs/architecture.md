# Conjet Architecture

Conjet starts as a shared Apple Virtualization.framework Linux VM with a thin
Swift CLI, a launchd-compatible daemon, a Unix-domain control socket, and
native-Linux storage for container hot paths.

The first implemented surface is intentionally small:

- `conjet doctor` records host capabilities.
- `conjetd` exposes `ping`, `status`, and `stop` over `~/.conjet/run/conjetd.sock`.
- `conjetd` now owns VM lifecycle commands over that socket: `vm-start`,
  `vm-stop`, and `vm-status`.
- `ConjetBench` records repeatable benchmark JSON.
- `PathClassifier` encodes the first ConjetFS placement policy.
- `EnergyGovernor` encodes low-power runtime states that VM and container
  scheduling can use as the runtime matures.

## VM Boot Substrate

The VZ layer now manages:

- manifest at `~/.conjet/state/vm/manifest.json`
- sparse raw root/data disks
- serial log at `~/.conjet/logs/vm-serial.log`
- bootstrap VirtioFS share at `~/.conjet/state/vm/bootstrap`
- NAT network device
- virtio socket device for the future guest agent
- gzip-compressed `newc` initramfs generation from a supplied static Linux
  `/init` binary
- EFI disk boot through `VZEFIBootLoader` with an owned EFI variable store
- optional cloud-init NoCloud seed ISO attached as a read-only disk
- compressed raw EFI disk import for Conjet-core `.raw.gz` guest artifacts
- Docker API forwarding from `~/.conjet/run/docker.sock` to guest VSOCK port
  2375 after VM start

`conjet vm fetch-fedora` and `conjet vm fetch-alpine` are boot-asset fetchers,
not complete container-runtime images. The smoke-test blocker is now concrete:
the downloaded Fedora and Alpine `vmlinuz` files are compressed ARM64 EFI
zboot artifacts, while the current boot path uses `VZLinuxBootLoader`. Conjet
records that boot artifact kind in the manifest and rejects it before calling
Virtualization.framework.

There are now two viable boot lanes:

1. Direct kernel: `conjet vm init --kernel PATH --initrd PATH` uses
   `VZLinuxBootLoader` and expects a direct ARM64 Linux `Image`/`vmlinux`.
2. EFI disk: `conjet vm import-efi-disk --image PATH` imports a full
   EFI-bootable distro/cloud image, converts qcow2-style inputs to raw through
   `qemu-img`, creates an EFI variable store, and boots it through
   `VZEFIBootLoader`.

`conjet vm fetch-ubuntu-cloud --release noble --cloud-init-docker` is the
first concrete EFI-disk bring-up command. It downloads Ubuntu's ARM64 cloud
image, probes the real disk format even though Ubuntu uses an `.img` suffix,
converts QCOW2 to raw, expands the raw boot disk to 16 GiB by default, builds
the Docker cloud-init seed when requested, and writes an EFI-disk manifest
ready for `conjet vm start`.

`guest/image/conjet-core` is the Conjet-owned version of that lane. It starts
from Ubuntu minimal cloud image, installs Docker and the guest VSOCK bridge
inside the disk image, configures DHCP and vsock module loading, disables
cloud-init first-boot waits, and emits a `.raw.gz` artifact. The
`conjet vm fetch-conjet-core --image PATH.raw.gz` command imports that artifact
directly and does not attach the generic cloud-init Docker seed.

The user-facing bootstrap is `conjet start`. If no VM manifest exists, the CLI
queries the latest GitHub release for `zdxsector/conjet` by default, selects the
Conjet-core `.raw.gz` asset that matches the host architecture, downloads the
matching `.sha512sum` asset when present, verifies it, imports the EFI disk, and
then starts `conjetd` plus the VM. The release repository can be overridden via
`CONJET_CORE_REPOSITORY` or `[images].conjet_core_repository` in
`~/.conjet/config.toml`.

`conjet vm build-initramfs --init PATH` now builds the host-side archive needed
for that next image phase. It does not synthesize a Linux binary; the supplied
`PATH` must already be a static guest executable suitable for running as PID 1.

`conjet vm build-cloud-init-seed` creates a NoCloud `cidata` ISO whose
cloud-init payload installs and starts Docker inside Ubuntu, Fedora, or
Alpine-derived guests. It emits serial markers, copies bootstrap logs into the
host VirtioFS bootstrap share when available, and installs a small Python
guest-side bridge that listens on VSOCK port 2375 and forwards to
`/var/run/docker.sock`.

On the host, `conjetd` starts a Docker socket bridge after the VM reaches
`running`. That bridge owns `~/.conjet/run/docker.sock`, accepts Docker API
connections from the local Docker CLI, and forwards each byte stream to the
guest's VSOCK listener. If the guest bridge is not ready yet, the host bridge
returns HTTP 503 instead of silently falling back to Docker Desktop, Colima, or
OrbStack.

The verified Ubuntu lane now supports `conjet run hello-world` through this
socket path.

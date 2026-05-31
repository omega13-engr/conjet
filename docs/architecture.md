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
- `ConjetFS` project attach syncs host-authoritative files into a Docker
  volume mounted at `/workspace`, giving containers a native-Linux workspace
  for dependency and build churn.
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
- optional VirtioFS host shares for `/Users` and `/Volumes`, exposed as
  `conjethostusers` and `conjethostvolumes`, so the guest Docker daemon can
  resolve normal macOS bind-mount source paths

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
cloud-init first-boot waits, mounts the Conjet host `/Users` and `/Volumes`
VirtioFS shares, and emits a `.raw.gz` artifact. The
`conjet vm fetch-conjet-core --image PATH.raw.gz` command imports that artifact
directly and does not attach the generic cloud-init Docker seed.

The user-facing bootstrap is `conjet start`. If no VM manifest exists, the CLI
queries GitHub releases for `omega13-engr/conjet` by default, selects the newest
stable `conjet-core-vX.Y.Z` release with a `.raw.gz` asset that matches the host
architecture, downloads the matching `.sha512sum` asset when present, verifies
it, imports the EFI disk, and then starts `conjetd` plus the VM. The release
repository can be overridden via `CONJET_CORE_REPOSITORY` or
`[images].conjet_core_repository` in `~/.conjet/config.toml`.

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

## ConjetFS MVP

The first ConjetFS implementation is intentionally host-driven. The CLI writes
project metadata under `.conjet/project.json`, combines `.conjetignore`,
`.dockerignore`, `.gitignore`, and built-in defaults, then stages only
host-authoritative files according to `PathClassifier`. `conjet project attach`
creates a Docker volume named for the active profile and project, copies the
staged files into `/workspace`, and records a manifest of synced paths and file
signatures under Conjet state so future pushes copy only changed files and can
delete removed host files without touching VM-native dependency or build
folders.

`conjet project run` is the first user-facing fast path built on that model: it
pushes the current project state, mounts the project Docker volume into a
container at `/workspace`, and keeps package-manager and build churn off the
macOS filesystem by default. `conjet sync watch` is the current developer
bridge: it uses macOS FSEvents by default, debounces batches, checks manifest
dirtiness, and pushes only changed host-authoritative files. `--poll` keeps the
older polling path available for fallback debugging. `conjet sync export` is
the explicit escape hatch for copying selected generated outputs from the
VM-native workspace back to macOS.

This path does not yet provide explicit guest-side inotify/fanotify replay or
broad two-way sync. Its purpose is to establish the first benchmarkable workflow
where `npm install`, `pnpm install`, Cargo `target`, package caches, and other
many-small-file churn stay inside Linux-native storage by default.

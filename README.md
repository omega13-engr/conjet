# Conjet

Conjet is a macOS container runtime prototype focused on light idle behavior,
low power usage, and faster filesystem-heavy development workflows.

This repository currently implements the first real container-runtime slice from
`CONJET_IMPLEMENTATION_PLAN.md`:

- SwiftPM package with `conjet` and `conjetd`.
- Host capability and Virtualization.framework probing.
- User-scoped config at `~/.conjet/config.toml`, or `CONJET_HOME` for moving
  all Conjet state to another volume.
- Profile-scoped config/state. The `default` profile keeps the legacy
  `~/.conjet` layout; named profiles live under
  `$CONJET_HOME/profiles/<name>`.
- Unix-domain control socket at `~/.conjet/run/conjetd.sock` for the default
  profile, or the profile-specific `run/conjetd.sock` for named profiles.
- Benchmark JSON and Markdown result output.
- Initial ConjetFS path placement classifier.
- ConjetFS MVP project workflow: `conjet project init`, `conjet project
  attach`, `conjet sync push`, `conjet sync status`, `conjet sync repair`,
  `conjet sync watch`, and `conjet sync export` stage host-authoritative files
  into a Conjet-owned Docker volume while dependency/build/cache paths stay
  VM-native.
- `conjet sync watch` uses macOS FSEvents by default to trigger incremental
  host-to-VM pushes, with `--poll --interval N` available as a conservative
  fallback.
- Initial energy governor state and resource policy model.
- VZ VM asset management, raw root/data disk creation, serial log path, NAT/vsock/bootstrap-share configuration, and daemon VM lifecycle commands.
- VM boot artifact classification, with both direct-kernel and EFI-disk boot
  lanes represented in the manifest.
- EFI cloud/distro disk import, including qcow2-to-raw conversion when
  `qemu-img` is available.
- First-class Ubuntu Noble ARM64 cloud image fetch/import path for the
  QCOW2-backed `.img` published by Ubuntu, including raw boot disk expansion
  for Docker-capable cloud-init boots.
- Conjet-core image import path for prebuilt Conjet-owned `.raw.gz` EFI guest
  artifacts.
- Conjet-core image builder under `guest/image/conjet-core`, modeled after the
  colima-core flow: fetch Ubuntu minimal cloud image, mutate it in a privileged
  Docker builder, and emit a compressed raw disk with Docker and the Conjet
  guest VSOCK bridge baked in.
- One-command first-run setup: `conjet start` auto-resolves the latest
  Conjet-core GitHub release for the host architecture, downloads the
  `.raw.gz` image, verifies the `.sha512sum` asset when present, imports it,
  starts `conjetd`, starts the VM, and configures Docker context `conjet`.
- Colima-style profile flags on `conjet start`: `--profile`, `--cpu`,
  `--memory`, `--disk`, `--runtime`, and `--arch`. New profiles default to
  4 CPUs, 8 GiB memory, 100 GiB data disk, Docker runtime, and `aarch64`.
- GitHub Actions release automation for Conjet-core image artifacts on pushes
  that change `guest/image/conjet-core/**`, plus manual workflow dispatch.
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
swift run conjet bench docker-compare --contexts conjet,colima --iterations 3 --warmup --markdown
swift run conjet bench power --runtime conjet --seconds 60 --interval 1 --markdown
swift run conjet bench release-gate --contexts conjet,orbstack,colima --iterations 3 --warmup --output-dir bench/reports/release-gate-local --json
swift run conjet bench docker-compare --contexts conjet,colima \
  --workloads npm-install,pnpm-install,copy-node-modules,cargo-build,bind-npm-install,volume-npm-install,conjetfs-npm-install,bind-cargo-build,volume-cargo-build,conjetfs-cargo-build,named-volume-io,tmpfs-volume-io \
  --iterations 1 --warmup --markdown
swift run conjet sync classify node_modules/react/index.js
swift run conjet project init .
swift run conjet project attach .
swift run conjet sync status .
swift run conjet sync watch .
swift run conjet power policy warm-idle
```

For daemon and VM lifecycle testing, build first so `conjet` can find sibling
`conjetd`:

```sh
swift build
build-support/sign-debug.sh
export CONJET_HOME="$(mktemp -d /tmp/conjet.XXXXXX)"
.build/debug/conjet start
```

`CONJET_HOME` is the storage root. Use it to move Conjet from `~/.conjet` to an
external drive:

```sh
export CONJET_HOME=/Volumes/ExternalSSD/conjet
.build/debug/conjet start
```

Profiles are isolated under that root. The default profile remains at
`$CONJET_HOME` for backward compatibility; named profiles use
`$CONJET_HOME/profiles/<name>` and get their own config, daemon socket, VM
state, Docker socket, logs, and Docker context:

```sh
.build/debug/conjet start --profile default
.build/debug/conjet start --profile work --cpu 4 --memory 8 --disk 100 --runtime docker --arch aarch64
.build/debug/conjet profile status --profile work
.build/debug/conjet profile list
```

`--disk` accepts either a GiB value or a path to a custom EFI boot disk image.
If a custom image path is set before the profile has VM assets, Conjet imports
that image instead of downloading Conjet-core. The Docker runtime is currently
the supported runtime. Profiles also default to host path sharing for `/Users`
and `/Volumes` so ordinary Docker bind mounts can work when the guest image has
the matching VirtioFS mount units; disable with `enable_host_mounts = false` in
`config.toml` when testing stricter ConjetFS-only behavior.

On first run, `conjet start` fetches the latest Conjet-core image release from
`zdxsector/conjet`. Override the release source with either
`CONJET_CORE_REPOSITORY=OWNER/REPO` or this config entry:

```toml
[images]
conjet_core_repository = "OWNER/REPO"
```

After VM start, Conjet creates or updates Docker context `conjet` for the
default profile, or `conjet-<profile>` for named profiles, points it at the
profile Docker socket, and makes it the active Docker context. This lets normal
Docker commands target Conjet:

```sh
docker context ls
docker ps
```

To open a root shell in the Conjet Linux guest through the Docker socket bridge:

```sh
.build/debug/conjet shell
.build/debug/conjet shell -- uname -a
```

To move a project into the ConjetFS MVP path, initialize it and attach it to a
VM-native workspace volume:

```sh
.build/debug/conjet project init /path/to/project
.build/debug/conjet project attach /path/to/project
.build/debug/conjet sync watch /path/to/project
.build/debug/conjet project run --path /path/to/project node:22-alpine npm install
```

`project attach` syncs source files, lockfiles, Dockerfiles, compose files, and
other host-authoritative project metadata into the volume. Dependency folders
such as `node_modules`, `vendor`, `target`, `.next`, `.turbo`, `.cache`, and
language build outputs are not copied from macOS, so package managers and
build tools create them inside Linux-native storage.

`project run` performs the sync and then runs the container with the project
volume mounted at `/workspace`; use `--no-sync` to reuse the existing volume
without another host-to-VM push.

`sync push` is incremental after the first push: ConjetFS records file
signatures in its profile state and only recopies changed host-authoritative
files on later pushes. `sync status` reports whether the project is dirty,
`sync repair` replays the host-authoritative view into the volume, `sync watch`
uses FSEvents by default to push changed files for development loops, and
`sync export PATH... --to DEST --path /path/to/project` explicitly copies
selected generated outputs from the VM-native workspace back to macOS. Use
`sync watch --poll --interval 1` when debugging the fallback polling path.

Manual VM setup commands remain available for development:

```sh
.build/debug/conjet vm fetch-fedora --release 43
.build/debug/conjet vm validate  # reports current boot incompatibility for fetched netboot kernels
.build/debug/conjet vm build-initramfs --init /path/to/linux-arm64-static-init
.build/debug/conjet vm fetch-ubuntu-cloud --release noble --cloud-init-docker --force
.build/debug/conjet vm import-efi-disk --image /path/to/cloud-image.qcow2 --cloud-init-docker
.build/debug/conjet vm fetch-conjet-core --image /path/to/conjet-core.raw.gz --force
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

For the Conjet-owned minimal image path, build the Ubuntu minimal guest image
and import its `.raw.gz` artifact:

```sh
cd guest/image/conjet-core
make image
cd ../../..
.build/debug/conjet vm fetch-conjet-core \
  --image guest/image/conjet-core/dist/out/conjet-ubuntu-24.04-minimal-cloudimg-aarch64-docker.raw.gz \
  --force
.build/debug/conjet vm validate
```

The Conjet-core artifact already contains Docker and the guest VSOCK bridge, so
it does not need the `--cloud-init-docker` seed used by the generic Ubuntu
cloud-image smoke path.

GitHub release automation lives in `.github/workflows/conjet-core-image.yml`.
It builds `aarch64` and `x86_64` Conjet-core images, uploads the `.raw.gz`,
`.sha512sum`, and `.json` artifacts, then publishes a GitHub release marked as
latest. That is the release stream consumed by `conjet start`.

## Current Boundary

Conjet can now run a Docker image through a real Virtualization.framework
Ubuntu guest. `conjet start` downloads the latest Conjet-core release, boots
the baked Ubuntu minimal image, starts guest Docker, exposes
`~/.conjet/run/docker.sock`, configures Docker context `conjet`, and supports
normal `docker`, `docker compose`, and `conjet shell` workflows.

The custom minimal Conjet guest image now has a local builder and importer, and
ConjetFS has an incremental one-way sync path through Docker volumes, an
FSEvents-backed host watch command with a polling fallback, and explicit
artifact export. The remaining performance claim gate is repeated raw-JSON
P50/P95 benchmark evidence against OrbStack and tuned Colima with the ConjetFS
workflow enabled, followed by a passing
`conjet bench release-gate` report. The release gate writes Docker, idle,
power, combined raw JSON, and Markdown artifacts before it allows any
faster-than-OrbStack claim.
Smoke testing downloaded Alpine and Fedora boot assets, and Conjet classifies
those public netboot `vmlinuz` artifacts as compressed ARM64 EFI zboot kernels
before they reach Virtualization.framework.

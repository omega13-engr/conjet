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
13. `guest/image/conjet-core` builds a Conjet-owned Ubuntu minimal cloud-image
    derivative as a `.raw.gz` EFI disk artifact with Docker and the guest
    VSOCK bridge baked in.
14. `conjet vm fetch-conjet-core --image PATH.raw.gz` imports that compressed
    raw artifact directly, without the cloud-init Docker seed.
15. `conjet start` now performs first-run VM setup automatically by resolving
    the latest Conjet-core GitHub release, selecting the host-architecture
    image, verifying the checksum when present, importing it, and then starting
    the daemon and VM.
16. `.github/workflows/conjet-core-image.yml` builds and publishes Conjet-core
    image releases for `aarch64` and `x86_64`.

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
- The Conjet-core builder and `.raw.gz` import path have been added. The builder
  follows the colima-core shape but emits a Conjet-specific Ubuntu minimal image
  with Docker and the VSOCK bridge preinstalled.
- `conjet start` is now the user-facing first-run path instead of requiring a
  separate manual image fetch command.
- `conjet start` and `conjet vm start` now create or update Docker context
  `conjet`, point it at `~/.conjet/run/docker.sock`, and make it current.

Observed progress on 2026-05-30:

- Conjet profiles and `CONJET_HOME` are implemented for isolated state roots,
  sockets, VM assets, logs, and Docker contexts.
- Conjet now exposes `/Users` and `/Volumes` to the guest with VZ VirtioFS
  directory shares when `enable_host_mounts = true`.
- The Conjet-core image scripts and cloud-init seed mount `conjethostusers` and
  `conjethostvolumes` inside the guest. Existing images can be repaired at
  startup by `HostShareMounter`, which enters the guest host namespace through
  Docker and mounts the VirtioFS tags.
- A live smoke test on the default profile confirmed Docker bind mounts through
  Conjet can read `/Users/sly/Workspace/Personal/conjet/README.md` from an
  Alpine container.
- `conjet project run [--path PATH] IMAGE [CMD...]` was added as the first
  product-facing ConjetFS fast path: it syncs host-authoritative project files
  into the project volume and runs the container from `/workspace`.
- ConjetFS sync is now incremental after the first push. The profile manifest
  stores file signatures, later pushes stage only changed host-authoritative
  files, and `conjet sync status` reports dirty/clean state from changed and
  removed paths.
- `conjet sync watch`, `conjet sync repair`, and `conjet sync export` were
  added. Watch now uses a host-side FSEvents stream by default, with
  `--poll --interval N` retained as a conservative fallback; export is explicit
  so generated artifacts can be copied back without turning dependency/build
  churn into host-synced state.
- A smoke test confirmed `conjet project run --path /tmp/conjet-project-run-smoke
  alpine:3.20 sh -c 'test -f package.json && pwd'` ran from `/workspace`.
- `swift test` passes 63 tests, including ConjetFS coverage for unchanged
  incremental sync, modified-file dirty detection, removed-file cleanup, and
  explicit artifact export.
- A live smoke test initialized a temporary ConjetFS project, pushed it into a
  Conjet Docker volume, verified clean `sync status`, ran `sync watch --once`,
  created `/workspace/dist/out.txt` inside the VM-native volume, and exported
  `dist` back to macOS with `conjet sync export`.
- A live FSEvents smoke test initialized a temporary ConjetFS project on the
  external SSD-backed Conjet profile, ran `conjet sync watch --debounce 0.1`,
  edited `src/index.js` on macOS, and verified the Conjet Docker volume
  contained the changed file while `conjet sync status` returned clean.
- `conjetfs-hot-reload` now benchmarks the FSEvents-backed watch path instead
  of calling `sync` directly after the edit. A Conjet-only live sample at
  `/Volumes/ExternalSSD/dev_worskpace/conjet-bench-reports/20260530-fsevents-hot-reload/conjetfs-hot-reload.json`
  exited 0 with `hot_reload_seconds = 0.479`, `watch_sync_seconds = 0.343`, and
  `watch_event_paths = 1`.
- OrbStack 2.1.3 is installed and exposes Docker context `orbstack`. A
  watcher-focused smoke report was written to
  `/Volumes/ExternalSSD/dev_worskpace/conjet-bench-reports/20260530-orbstack-smoke/hot-reload-contexts.json`.
  `container-start` passed on Conjet, OrbStack, and Colima. The in-container
  `fs.watch` bind-mount probe passed on OrbStack but timed out on Conjet and
  Colima, while `conjetfs-hot-reload` passed on all three contexts. This keeps
  the direct bind watcher gap visible and proves why the ConjetFS path is the
  current fast/hot-reload path.
- A repeated 3-sample hot-reload matrix was written to
  `/Volumes/ExternalSSD/dev_worskpace/conjet-bench-reports/20260530-orbstack-hot-reload-3x/hot-reload-contexts.json`.
  ConjetFS hot reload had 0 failures on all three contexts: Conjet P50/P95
  `0.425/0.428s`, OrbStack P50/P95 `0.471/0.475s`, and Colima P50/P95
  `0.443/0.448s`. Direct bind `fs.watch` still timed out on Conjet and Colima
  and passed on OrbStack with P50/P95 `0.133/0.200s`.
- A 3-iteration benchmark report was generated at
  `bench/reports/docker-conjetfs-contexts-20260530-090525.md` on an Apple M1 Pro
  with AC power and nominal thermals. All 72 benchmark samples exited 0. Conjet
  beat Colima P50 on the measured bind npm, bind pnpm, bind Cargo, ConjetFS npm,
  ConjetFS pnpm, ConjetFS Cargo, copy-node-modules, named-volume IO, tmpfs IO,
  volume npm, volume pnpm, and volume Cargo workloads in that run.
- A hot reload report was generated at
  `bench/reports/docker-hot-reload-contexts-20260530-112320.md` on battery power
  and nominal thermals. All 12 samples exited 0. Conjet and Colima were nearly
  tied on direct bind hot reload P50, while the ConjetFS path measured lower
  P50 than Colima in that run.
- Short idle process samples were added through `conjet bench idle`. The first
  5-second local sample showed Conjet at 0.000 percent mean matched CPU and
  Colima at 18.800 percent mean matched CPU, but this is not a release-grade
  power result.
- `conjet bench power` was added as the release-path power probe. It wraps
  noninteractive `powermetrics`, parses power rails plus matched process
  energy/wakeup signals when present, and preserves permission failures as
  benchmark failures instead of hiding missing evidence.
- A local `conjet bench power --runtime conjet --seconds 1 --interval 1
  --no-sudo --json` smoke confirmed structured output on permission failure:
  exit code 1, `powermetrics must be invoked as the superuser`, and machine
  profile metadata captured.
- `conjet bench gate` was added as the faster-than-OrbStack claim verifier. It
  accepts raw JSON reports, requires the release workload matrix to include
  Conjet plus OrbStack and tuned Colima, enforces minimum sample counts and zero
  failures, and rejects the claim unless Conjet P50/P95 is at or below each
  baseline for each required workload or metric. Hot-reload rules now compare
  the `hot_reload_seconds` metric directly.
- A local gate smoke generated one raw JSON Conjet idle report and confirmed
  `conjet bench gate` exits nonzero with `passed=false` and missing benchmark
  requirements instead of allowing an under-evidenced claim.
- `conjet bench release-gate` was added as the production evidence
  orchestrator. It collects Docker workload samples, idle CPU samples, and
  `powermetrics` power samples for the requested contexts, writes
  `docker.json`, per-runtime idle/power reports, `all-results.json`,
  `all-results.md`, `gate.json`, and `gate.md`, then exits nonzero unless the
  same claim gate passes.
- Unit coverage now verifies that the release-gate runner writes all expected
  artifacts and still fails when OrbStack evidence is not collected.
- This is still not enough to claim "faster than OrbStack": OrbStack was not
  installed as a Docker context on the test machine, power/wakeup probes still
  need controlled repeated runs, guest-side inotify/fanotify replay is not yet
  implemented, and the Colima run had large outliers that need controlled
  reruns before release marketing claims.

Next required work:

- Add OrbStack and Docker Desktop to the same repeated benchmark matrix.
- Run `bench power` under configured noninteractive `powermetrics` for Conjet,
  OrbStack, and tuned Colima.
- Run `bench release-gate` on raw JSON release reports and publish the failed or
  passed gate result as a release artifact.
- Add guest-side inotify/fanotify replay from the FSEvents watch stream once
  correctness and interruption handling are specified.
- Investigate the Colima outliers and rerun under controlled thermal, power,
  and cache conditions.
- Add release signing or attestation after the `.sha512sum` release flow is
  stable.
- Replace Docker-package bootstrap with a tighter runtime stack containing
  containerd, runc, BuildKit, and the guest bridge once Conjet's Docker API
  surface no longer needs dockerd.

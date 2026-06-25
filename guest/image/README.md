# Guest Image

This directory holds build recipes for Conjet guest images.

The first Conjet-owned image recipe is `conjet-core/`. It follows the
Conjet Core model: create a partitioned raw disk, bootstrap Ubuntu directly in a
privileged Docker builder, and emit a compressed root disk artifact for Conjet
only. The baked image includes Docker, the Conjet guest VSOCK bridge, netplan
DHCP fallback, and vsock module loading.

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
  --image guest/image/conjet-core/dist/out/conjet-ubuntu-24.04-rootfs-aarch64-docker.raw.gz \
  --force
```

The direct-kernel image path remains useful once Conjet has its own static
Linux guest agent and init system:

Current host support can create the initramfs wrapper once a static Linux
`/init` exists:

```sh
conjet vm build-initramfs --init /path/to/linux-arm64-static-init --output initramfs.cpio.gz
```

For Phase 9 network proof, Conjet also has a custom BusyBox-based initramfs
lane. It does not use Debian or Ubuntu userspace; it packages a static Linux
ARM64 BusyBox binary, runs DHCP on the virtio-net interface, probes an outbound
HTTP URL after an explicit DNS lookup, and starts a guest HTTP service for host
forwarded-port QA.

Build the pinned static BusyBox artifact first:

```sh
guest/kernel/scripts/build-busybox.sh
```

The script emits `guest/kernel/dist/busybox-<version>-conjet-arm64/busybox`,
its `.config`, and a manifest with source and output SHA-256 values. Then build
the network-proof initramfs from that artifact:

```sh
conjet vm build-initramfs \
  --network-proof \
  --busybox guest/kernel/dist/busybox-1.38.0-conjet-arm64/busybox \
  --proof-url http://example.com \
  --guest-service-port 8080 \
  --output conjet-network-proof-initramfs.cpio.gz
```

The guest console emits `CONJET_NETWORK_DNS_RESOLVED` after DNS lookup,
`CONJET_NETWORK_OUTBOUND_TCP_OK` after outbound TCP, and
`CONJET_NETWORK_SERVICE_TOKEN` before the proof service starts. The guest HTTP
response includes the same token with `CONJET_NETWORK_FORWARDED_PORT_OK`, so
Phase 9 is not production-ready until the host fetch proves a same-boot
forwarded-port response through vmnet.

After importing the custom kernel/initramfs assets into an isolated `CONJET_HOME`,
run the single Phase 9 proof command. It boots the signed transient VM, starts
vmnet, installs a localhost forwarded-port rule, captures the guest HTTP
response, emits proof JSON, and writes Phase 9 evidence:

```sh
conjet vm backend phase9-network-proof \
  --output-dir /tmp/conjet-qa/phase9-network \
  --host-port 18080 \
  --guest-port 8080 \
  --require-ready

conjet vm backend readiness \
  --evidence /tmp/conjet-qa/phase9-network/phase9-evidence.json \
  --require-phase 9
```

The command preflights the configured manifest before booting. It requires a
direct Linux kernel and the generated network-proof initramfs markers, including
the DNS proof marker, so a plain initramfs or distro installer initrd fails
before any HVF VM work starts.

The lower-level diagnostic sequence remains available when the combined proof
command blocks:

```sh
conjet vm backend boot-attempt \
  --start-vmnet \
  --require-init-ready \
  --timeout-ms 30000 \
  --console-log /tmp/conjet-qa/network-console.log \
  --network-proof-host-port 18080 \
  --network-proof-guest-port 8080 \
  --network-proof-response /tmp/conjet-qa/forwarded-port-response.txt

conjet vm backend network-proof \
  --console-log /tmp/conjet-qa/network-console.log \
  --host-response /tmp/conjet-qa/forwarded-port-response.txt \
  --output-dir /tmp/conjet-qa/proofs \
  --require-ready

conjet vm backend net-smoke \
  --outbound-proof /tmp/conjet-qa/proofs/networkOutboundTCP.json \
  --forward-proof /tmp/conjet-qa/proofs/networkForwardedPort.json \
  --record-evidence \
  --evidence /tmp/conjet-qa/phase9-evidence.json
```

That future direct-kernel recipe should combine the initramfs with a direct
ARM64 Linux `Image`/`vmlinux` kernel, then add containerd, runc, BuildKit, and
the Docker socket bridge.

The old VZ prebuilt distro-image bring-up lane has been removed from the
release path. Use `conjet start` for normal bootstrap, or
`conjet vm fetch-conjet-core --image ... --kernel ...` for explicit local image
testing.

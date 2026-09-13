# Runtime feature review and VPN compatibility plan

## Scope

Review Docker API/CLI and Compose, container/image/volume/network management,
machine lifecycle, activity/process samples, command history, SSH/terminal,
TCP/UDP publishing and privileged ports. Dynamic memory is explicitly excluded.
Do not restart, replace, or modify the user's installed runtime during QA.

## Evidence and constraints

- At review start the host was not connected to a VPN. On September 13 the user
  connected the full tunnel and the new backend was tested live through `utun6`.
- At review start Jetstream had only `vmnet` shared NAT for guest egress. Host port
  publishing is a separate VSOCK path and must retain its bind policy.
- Baseline screenshots showed truncated networking pickers and an ambiguous
  "connected" badge that does not prove guest internet connectivity.
- The installed Docker API responds, and its empty image/container inventories
  match the UI. Destructive or workload tests belong in the isolated QA VM.

## Implementation

1. Add host-socket egress with a bounded, nonblocking Ethernet stream between
   Rust virtio-net and an unprivileged network helper. Keep explicit vmnet mode.
   New connections use macOS routing and DNS, including VPN changes. No public
   DNS fallback, route edits, PF edits, or VPN bypass.
2. Reuse the maintained `gvisor-tap-vsock` IP stack through a small helper. Pin
   dependencies and bundle/sign it with the VMM. Expose only an inherited private
   socket, without the upstream HTTP forwarding/administration API. This avoids
   inventing a TCP stack and does not replace Jetstream/HVF VM execution.
3. Preserve TCP and UDP publication through existing ConjetNet and descriptor
   passing through the privileged port helper. Test backpressure, partial frames,
   bounded queues, helper failure and shutdown, and explicit backend selection.
4. Make networking mode and its limits visible, and repair the cramped policy
   controls using existing UI components.
5. Run focused regressions, the project suites, screenshot QA, and an isolated
   Docker/Compose feature matrix with data checks. Include DNS, registry access,
   HTTP(S), UDP, port conflicts, 80/443 when safely available, and terminal I/O.
6. Retain an evidence-backed review with confirmed defects, fixes, unsupported
   semantics and unverified cases. Remove temporary builds, VMs and workloads.

## Compatibility boundaries to assess

Linux containers run inside a Linux VM. `--network host` refers to that VM;
macOS LAN publication follows Conjet's configured bind policy. IPv6 egress,
raw ICMP, privileged-helper authorization, multi-machine features, filesystem
sharing and architecture emulation need explicit evidence and cannot be inferred
from a successful image pull. No OrbStack or power/throughput benchmark is part
of this review.

## Design references

- [Docker's VPN networking approach](https://docs.docker.com/desktop/features/networking/networking-how-tos/)
- [Apple vmnet shared NAT](https://developer.apple.com/documentation/vmnet/operating_modes_t/vmnet_shared_mode)
- [gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock/tree/v0.8.9)

## Completion record

Host-socket egress, bounded transport, configuration, UI, packaging and regression
coverage are implemented. Live connected-VPN and isolated Docker/Compose checks
are recorded in [the full review](runtime-feature-review.md), with screenshot
evidence and confirmed compatibility gaps. The final bundle was verified locally;
nothing was committed, pushed, installed over the user's runtime, or released.
The disposable app/daemon/VM/helper, workloads, mounted DMG and temporary QA root
were cleaned up; [cleanup evidence](qa/runtime-features-2026-09-13/cleanup.json).

Follow-up priorities are ordinary macOS bind sharing, guest SSH login readiness,
durable privileged-helper authorization, and complete/bounded process sampling.
These remain open findings rather than claims of full Docker compatibility.

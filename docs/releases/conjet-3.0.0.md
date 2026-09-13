# Conjet 3.0.0

This major release adds host-based networking for full-tunnel VPN connections and
fixes container monitoring, command handling, SSH readiness and the Jetstream
entropy device. It is an **ad-hoc signed, non-notarized** macOS Apple Silicon release.
The known compatibility gaps below remain; this release is not a claim of complete
Docker compatibility or completion of the production-readiness review.

## Changes

- Route guest traffic through the bundled host networking helper and native macOS
  DNS. Image pulls, container DNS and HTTPS were exercised with a full-tunnel VPN.
  The host backend is the default; vmnet remains an explicit configuration option.
- Show processes for every running container using bounded concurrency, cancel
  stale refreshes, and display partial sampling failures.
- Validate Compose projects before actions and preserve quoted command arguments
  in Compose and the Dockerfile editor. Reject malformed quotes before execution.
- Preview unused volumes and confirm explicit selections before deletion. Display
  actual host-listener failures separately from Docker's published-port metadata.
- Distinguish prepared terminal sessions from completed commands and improve
  command readability, port displays and sidebar layout.
- Correct fragmented Docker HTTP readiness parsing. Provide operating-system
  entropy through virtio RNG, including queue reset and repeated notification handling.
- Bundle an authenticated persistent privileged-port service for future team-signed
  builds. Ad-hoc builds retain the existing sudo-authorized helper fallback.
- Add Rust and host-networking race checks to the app release workflow.

## Core update

The companion **Conjet Core 1.3.1** rootfs starts `systemd-user-sessions.service`,
removing the boot-time SSH login gate. The CLI uses its explicit SSH configuration
without automatically editing the user's global SSH config. Install the Core
update when convenient using `conjet update`; that command restarts the active
runtime. The existing custom Linux 6.12.86 kernel source is unchanged.

## Known limitations

- **Live Mac bind mounts still fail** with `bind source path does not exist`.
  Jetstream does not yet provide the required host filesystem backend. Named
  volumes work; the unmodified chum-mem Compose stack was not validated because
  it depends on host bind mounts.
- **Administrator-authorized forwarding on ports 80/443 was not validated.**
  Unprivileged binds return `EACCES`. The persistent helper requires a team-signed
  build and administrator approval, and is disabled in this ad-hoc release.
- Full-tunnel VPN egress was checked, but VPN reconnect, split DNS, sleep/wake,
  external IPv6/raw ICMP, automatic proxy discovery, Swarm/plugins and broad
  emulation compatibility are not established.
- No OrbStack comparison, performance/power benchmark or full VoiceOver audit
  was performed. Gatekeeper may require explicit approval for this non-notarized app.

See [the readiness report](https://github.com/omega13-engr/conjet/blob/conjet-v3.0.0/docs/production-readiness.md)
for implementation details, unresolved failures and screenshot-backed local evidence.

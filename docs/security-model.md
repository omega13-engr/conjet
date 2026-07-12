# Security Model

The initial prototype has no privileged helper and no telemetry. The daemon
listens on a user-owned Unix-domain socket under `~/.conjet/run/`. VM image
signing, update policy, and Docker socket forwarding hardening belong to later
implementation phases.

For local Jetstream/HVF development, debug binaries are ad-hoc signed with
`com.apple.security.hypervisor` via `build-support/sign-debug.sh`. A
Developer ID/provisioned build is still required before distribution.

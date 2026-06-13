---
name: conjet-vm-engineering
description: Use for Conjet macOS Virtualization.framework engineering, Linux guest image work, cloud-init, initramfs, VM assets, Docker-in-VM behavior, networking, and boot diagnostics.
---

# Conjet VM Engineering

Use this skill when work touches macOS host VM control, Linux guest images,
boot-time configuration, VM networking, guest Docker services, or VM asset
updates.

## Context To Read

- `Sources/ConjetVZ/VirtualMachineController.swift`
- `Sources/ConjetVZ/VirtualizationProbe.swift`
- `Sources/ConjetVZ/VMAssetManifest.swift`
- `Sources/ConjetVZ/CloudInitSeedBuilder.swift`
- `Sources/ConjetVZ/InitramfsBuilder.swift`
- `Sources/ConjetVZ/DockerSocketBridge.swift`
- `Sources/ConjetVZ/NativeTCPBridgePool.swift`
- `Sources/ConjetVZ/DockerServiceQuiescer.swift`
- `Sources/ConjetCore/ConjetCoreReleaseResolver.swift`
- `guest/image/README.md`
- `guest/kernel/README.md`
- `guest/agent/README.md`
- `guest/image/conjet-core/README.md`
- `guest/image/conjet-core/scripts/image.sh`
- `guest/image/conjet-core/scripts/cloud-image.sh`
- `guest/image/conjet-core/scripts/conjet-boot-diagnostics.sh`
- `guest/image/conjet-core/scripts/conjet-docker-service-guard.sh`

## Engineering Rules

- Keep macOS host responsibilities separate from Linux guest responsibilities.
- Treat architecture, disk layout, and VM asset manifests as release-sensitive.
- Preserve boot diagnostics when changing cloud-init, initramfs, or guest service
  startup.
- Docker service changes inside the guest must account for host-facing socket
  bridge behavior.
- Do not assume guest Linux paths, service managers, or permissions behave like
  host macOS paths.

## Validation

```sh
swift test --filter VMImageStoreTests
swift test --filter CloudInitSeedBuilderTests
swift test --filter InitramfsBuilderTests
swift test --filter DockerSocketBridgeTests
swift test --filter DockerServiceQuiescerTests
swift test --filter ConjetCoreReleaseResolverTests
```

For image changes, also validate the relevant guest image script path described
in `guest/image/conjet-core/README.md`.

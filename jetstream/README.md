# Jetstream Rust VMM

Jetstream is the Rust microVM monitor intended to replace Conjet's Swift
Jetstream HVF experiment. It is developed and tested as a standalone binary
first, then bundled with Conjet Core once the guest boot path is complete.

Current local entry points:

```sh
build-support/run-jetstream-rust-local.sh
cargo run --manifest-path jetstream/Cargo.toml -- smoke --json
cargo run --manifest-path jetstream/Cargo.toml -- validate --manifest /path/to/vm-manifest.json --json
cargo run --manifest-path jetstream/Cargo.toml -- boot --manifest /path/to/vm-manifest.json --json
```

The crate follows a Firecracker-style split:

- `hvf`: thin, unsafe boundary around macOS Hypervisor.framework plus the bounded
  direct-kernel boot runner.
- `vmm`: validated configuration, memory layout, FDT generation, and machine
  lifecycle.
- `arch`: Apple Silicon/aarch64 machine constants.
- `devices`: PL011, PSCI, MMIO bus, and virtio-mmio transport models.

The Rust lane now assembles a Conjet direct-kernel boot RAM image, emits a Linux
FDT for the Conjet virt machine shape, creates an HVF VM, maps guest RAM,
initializes the boot vCPU, and runs a bounded exit loop that services PL011,
PSCI, system-register traps, and virtio-mmio transport register accesses. The
boot report is JSON-serializable for local QA and release evidence.

Current limit: the Rust lane advertises block, net, vsock, rng, and balloon
transports but does not yet execute their virtqueue backends or bridge Docker
API traffic to the host socket. Until those queue handlers are ported, Conjet
Core should continue using the existing Swift managed HVF path for full
Docker-ready runtime startup.

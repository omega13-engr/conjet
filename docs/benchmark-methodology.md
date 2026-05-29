# Benchmark Methodology

Benchmarks must include machine profile, power source, thermal state, command
line, runtime name, wall time, exit code, and workload metrics. Claims against
OrbStack, Colima, or Docker Desktop are not valid until raw JSON for every
runtime is kept under `bench/reports/`.

For Docker compatibility and Colima comparison, use:

```sh
conjet bench docker-compare --contexts conjet,colima --iterations 3 --warmup --json \
  --output bench/reports/docker-contexts.json
```

The runner intentionally uses Docker contexts instead of changing the global
Docker context. It records `docker-version`, `container-start`, `image-build`,
`copy-node-modules`, `npm-install`, `cargo-build`, `named-volume-io`,
`tmpfs-volume-io`, and `compose-up` for every context and iteration.

Use `--workloads NAME,...` for a targeted run when isolating one subsystem. For
example, use `--workloads npm-install,copy-node-modules,cargo-build` to focus on
dependency-heavy build behavior, or `--workloads named-volume-io,tmpfs-volume-io`
to focus on Docker-managed storage. Do not compare these results with older
reports that only included the original four Docker probes.

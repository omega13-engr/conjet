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
and `compose-up` for every context and iteration.

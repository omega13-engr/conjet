# Conjet Benchmark Harness

The harness starts before the runtime so performance claims remain testable.

Initial commands:

```sh
swift run conjet bench profile --json
swift run conjet bench small-files --files 10000 --bytes 128 --json
swift run conjet bench docker-compare --contexts conjet,colima --iterations 3 --warmup --markdown \
  --output bench/reports/docker-contexts.md
```

`docker-compare` runs the same Docker API, container start, image build,
`COPY node_modules`, `npm install`, `cargo build`, named-volume IO, tmpfs IO,
and small Compose startup probes against each named Docker context. Store raw
JSON or Markdown in `bench/reports/` before making performance claims against
OrbStack, Docker Desktop, Colima default, or Colima tuned VZ + VirtioFS.

For a focused subset, pass workload names explicitly:

```sh
swift run conjet bench docker-compare --contexts conjet,colima \
  --workloads npm-install,copy-node-modules,cargo-build,named-volume-io,tmpfs-volume-io \
  --iterations 1 --warmup --markdown
```

Available Docker workloads:

- `docker-version`
- `container-start`
- `image-build`
- `copy-node-modules`
- `npm-install`
- `cargo-build`
- `named-volume-io`
- `tmpfs-volume-io`
- `compose-up`

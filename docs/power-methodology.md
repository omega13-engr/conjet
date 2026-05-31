# Power Methodology

Conjet optimizes wakeups and energy-to-solution, not only wall time. Energy
claims are valid only when the standalone benchmark package records measured
`powermetrics` data.

Run the power gate with explicit privileges:

```sh
swift run --package-path benchmarks conjet-bench energy-gate \
  --contexts conjet,orbstack,colima \
  --workloads idle,container-start-loop,hot-reload-loop,compose-loop,npm-install,pnpm-install,cargo-build \
  --samples 10 \
  --require-power \
  --output-dir benchmarks/reports/energy-gate-local
```

The energy gate records, when available:

- average power in watts
- package and CPU power where `powermetrics` exposes them
- wakeups per second
- workload runtime
- energy-to-solution in joules
- power source, thermal state, and low power mode

`--require-power` means missing `powermetrics` data is a failed gate. Without
`--require-power`, missing privileges are reported as an honest skip and cannot
support any energy superiority claim.

Short active workloads should be repeated or padded with a minimum active
duration so `powermetrics` can collect nonzero samples. A workload with no power
samples is not valid energy evidence even if the wall-time command succeeded.

Remaining power work:

- Attach VM stats, guest cgroup stats, and ConjetFS sync queue metrics to the
  same timeline.
- Repeat idle and energy-to-solution runs under controlled thermal and power
  conditions.
- Keep Conjet, OrbStack, and Colima measurements in the same report set.

# Power Methodology

Conjet optimizes wakeups and energy-to-solution, not only wall time. The first
governor implementation emits deterministic resource policies. Runtime
benchmarking now has two host-side probes:

- `conjet bench idle` samples matching processes with `ps` and reports CPU and
  memory percent aggregates.
- `conjet bench power` wraps `powermetrics`, parses CPU/GPU/ANE/combined power
  rails, and records matched process energy-impact and wakeup signals when the
  text output contains them.
- `conjet bench energy` runs a workload while `powermetrics` samples the host,
  then records `energy_to_solution_joules_estimate` from combined mean power
  multiplied by workload duration.

Use noninteractive sudo for release evidence:

```sh
conjet bench power --runtime conjet --seconds 60 --interval 1 --markdown
conjet bench power --runtime colima --seconds 60 --interval 1 --markdown
conjet bench power --runtime orbstack --seconds 60 --interval 1 --markdown
```

Use active energy sampling for workload claims:

```sh
conjet bench energy --runtime conjet --workload npm-install-energy --seconds 60 --interval 1 -- \
  docker --context conjet run --rm node:22-alpine node --version
conjet bench energy --runtime orbstack --workload npm-install-energy --seconds 60 --interval 1 -- \
  docker --context orbstack run --rm node:22-alpine node --version
```

The command runs `sudo -n powermetrics` by default. If the machine is not
configured for noninteractive `powermetrics`, the benchmark result exits
nonzero and the failure must stay in the report. That is intentional: missing
power evidence cannot support the energy-to-solution part of the
faster-than-OrbStack claim.

Remaining power work:

- Attach VM stats, guest cgroup stats, and ConjetFS sync queue metrics to the
  same timeline.
- Repeat idle and energy-to-solution runs under controlled thermal and power
  conditions.
- Keep Conjet, OrbStack, and tuned Colima measurements in the same report set.

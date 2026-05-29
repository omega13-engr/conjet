# Conjet Benchmark Harness

The harness starts before the runtime so performance claims remain testable.

Initial commands:

```sh
swift run conjet bench profile --json
swift run conjet bench small-files --files 10000 --bytes 128 --json
```

Future runners should store raw JSON in `bench/reports/` and compare Conjet
against OrbStack, Docker Desktop, Colima default, and Colima tuned VZ +
VirtioFS under the same machine profile.

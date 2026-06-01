# ConjetNet Turbo

Turbo mode is a reserved ConjetNet design track. It is not enabled in this
build and is not part of any performance claim.

The intended direction is an explicit opt-in path that removes `conjetd` from
the hot byte path for high-throughput published ports, while preserving the
same safety model:

- no silent LAN exposure
- scoped macOS packet-filter or routing changes
- clear status output
- repair/cleanup for stale rules
- fallback to the standard proxy path

Current command behavior:

```sh
conjet network enable-turbo
```

returns that turbo mode is experimental and unavailable.

Benchmark reports must not include turbo superiority claims until a complete
implementation and network gate results exist.

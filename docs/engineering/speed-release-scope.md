# Experimental native execution

Conjet's experimental native mode runs a single digest-pinned, statically
linked ARM64 Linux executable in a temporary network-free Jetstream guest.
The local verification envelope is the Apple M1 Pro with two virtual CPUs
and a 2 GiB guest ceiling. Docker profiles have their own start and stop
path through the product daemon. [Native Docker default and rollback](../release.md#native-docker-default)

## Start a session

Use the packaged ARM64 Conjet CLI and the verified AArch64 Linux `Image`
from Conjet Core v1.3.1 (Linux 6.12.86). Check the kernel against the
SHA-512 sidecar from that release. Provide the expected SHA-256 of the
executable independently of the bytes being staged. In a terminal, run:

```sh
conjet native --experimental serve \
  --scratch /Volumes/ExternalSSD/dev_workspace/tmp \
  --kernel "$kernel_path" --kernel-sha512 "$kernel_sha512" \
  --executable "$executable_path" --sha256 "$executable_sha256"
```

Use an existing scratch directory with room for the private Unix socket
path. The ready JSON contains the session directory. While the first
command stays in the foreground, use a second terminal with the same
Conjet installation:

```sh
conjet native --experimental run --session "$session"
conjet native --experimental prepare --session "$session"
# Pass the returned result.token promptly, while it is still ready.
conjet native --experimental claim --session "$session" "$token"
conjet native --experimental status --session "$session"
conjet native --experimental stop --session "$session"
```

The installed guest supervisor is bundled with the app VMM. A branch-built
runtime can pass a trusted static supervisor via `serve --guest-init`.
Use a supervisor built from the same revision and the verified Core kernel.
Standard app and binary Homebrew installations carry the supervisor.
Homebrew source builds can stage it with the same release build procedure.

## Limits and failure handling

One session admits one active workload or one prepared slot. It retains
only the latest terminal record. The CLI never queues a second workload,
and raw API connections are limited to four. A ready slot expires after
five seconds, is bound to its boot and original specification, and is
consumed once. The explicit `memory --pressure on` command evicts unused
preparation. The guest's available-memory floor also gates preparation.
Guest free-page reporting retains Jetstream's normal page-ownership
checks.

The executable has a 4 MiB input limit. It receives no arguments or
environment, starts as UID/GID 65532 in a private writable `/work`,
and is limited to 16 MiB, four PIDs, and 500 millicores. Network,
mounts, host shares, stdin, ports, OCI images, and Docker flags are
outside this profile. Its syscall filter supports a narrow subset of
Linux operations. The guest limits execution to 30 seconds. The CLI
uses a separate operation deadline (3 seconds by default), followed
by bounded cancellation and cleanup when it has an admitted handle.

Run and claim return JSON with the exit and verified cleanup state.
Stdout and stderr are base64 encoded and capped at 64 KiB each. The
guest drains excess bytes and reports the corresponding loss counts.
`cancel --session "$session" "$token"` waits for verified cleanup.
A disconnect leaves ownership with the guest. Reconnect to inspect or
cancel the original handle. On an indeterminate submission, inspect
the session before acting. The CLI never restarts or falls back to
another workload. The API and exact-replay rules are documented in
the [launch service contract](launch-service-contract.md).

Stop the experiment with `stop` or interrupt its foreground process.
The latter requests guest drain before applying a bounded VM stop.
A clean shutdown confirms guest cleanup and removes the session
directory. The default VM lifetime is ten minutes (configurable from
30 seconds to 30 minutes). Disable the feature by ending the session
and omitting `conjet native --experimental`.

## Qualification and deferred research

See the [local qualification report](speed-qualification.md). It records
the tested hardware, timings, failures, and measurement boundaries. The
fresh comparative verdict remains [revise](fresh-runtime-gate.md). Second
hardware, privileged energy sampling, equivalent Kiri guest teardown,
and the sub-1 ms prepared research target remain deferred. This release
makes no superiority claim.

## Native Docker candidate

The native Docker candidate passed all 71 frozen compatibility cases
with Core dynamic memory and the pinned public Docker, Buildx, image,
and service fixtures. The separate Kiri comparison passed 81 of 91
pairs. The frozen suite covers a bounded ARM64 capability profile.
[Compatibility proof and limits](native-compatibility.md#docker-29101-optimized-candidate)

Production promotion requires the compatible workload matrix, independent
review, required CI and the app release lane's signing and notarization
gates. The isolated validation does not authorize production migration or
publication. [Release process](../release.md)

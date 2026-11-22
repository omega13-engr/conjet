# Speedup environment

## Current status

Official Kiri 0.2.2 is runnable for session-scoped tests. Live smoke and
cancellation checks passed on 2026-11-22. No Kiri process is left running.
Production Conjet remains running with its existing Docker context selected.
The branch-built Conjet candidate and `conjet-speedup` context remain pending
under SPEED-000; comparative performance benchmarks have not run.

The user accepted keeping test data on ExternalSSD while allowing the official
app's normal settings location. This replaces the earlier requirement for full
filesystem isolation. It does not require a patched competitor or a new account.

## Run official Kiri

From the repository root:

```sh
# Pull a small test image, verify execution, and stop the daemon/VM.
python3 build-support/run-kiri-speedup.py --smoke -- ps -a

# Run one Docker workload command while the managed Kiri session is alive.
python3 build-support/run-kiri-speedup.py -- run --rm --network none alpine:3.22 true
```

The foreground launcher starts the signed official daemon, waits for its API,
verifies the server identifies itself as Kiri 0.2.2, checks its private context
endpoint, runs the command, and stops its own daemon. SIGINT/SIGTERM and command
failure also enter cleanup. It never invokes Kiri setup, opens its UI, or enables
login services. Use this launcher rather than invoking the app directly.

The launcher rejects concurrent Kiri processes, an existing socket, occupied
router/DNS ports, and an existing Kiri Finder path. It holds an exclusive session
lock. It strips inherited Kiri, Docker, Buildx, and Conjet endpoint overrides from
child processes and uses an explicit private Docker config and context.

## Paths and settings

```text
Repository (ignored local installation)
  .speedup/tools/kiri-0.2.2/Kiri.app

/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-kiri/
  data/                  images, container/volume state, VM disk
  docker-config/         private context: kiri-speedup
  docker.sock            session endpoint, removed at shutdown
  logs/                  launcher-captured daemon output
  tmp/                   child temporary directory
  session.lock           prevents overlapping worker sessions
  last-session.json      latest result and production snapshots
  smoke-session.json     retained initial smoke evidence
  cancellation-session.json
```

The competitor context is `kiri-speedup`. Reserve `conjet-speedup` for the separate
Conjet candidate. Neither context should replace the user's current context.
The official daemon also writes its own settings, diagnostics and untrusted local
CA under `~/.kiri`; HOME is unchanged. No CA trust operation was run.
The user-approved exception is recorded here rather than claiming complete isolation.

Initial resources: 2 vCPUs, 2048 MiB guest ceiling. HTTP/HTTPS domain routers use
18080/18443 rather than production ports; official Kiri binds these on wildcard
addresses. Its local DNS listener uses loopback UDP 53535. No global resolver
file is installed. Finder mounting is disabled with KIRI_NO_FINDER=1.

Kiri's official VM shares `/Users`, `/Volumes`, and `/private`. This launcher is
operational separation, not a security sandbox for hostile containers. Test
workloads must use disposable data and must not bind-mount production data or
publish conflicting ports. CPU, memory, thermal state, and disk bandwidth remain
shared with production; record background load in benchmark reports.

## Official artifact verification

- Release: libracoder/kiri v0.2.2; source commit
  `686bffa5f38ba6ecc3d086c36ec7148cd7fb976a`.
- Archive: `https://github.com/libracoder/kiri/releases/download/v0.2.2/Kiri-0.2.2-arm64.tar.gz`.
- SHA256 checked against official SHA256SUMS:
  `b08f568ed7dc95e4e1a09acb718daaf21019fb7aad96345c476ff5ed695d77fb`.
- Code signature validation: `codesign --verify --deep --strict` passed;
  identifier `dev.kiri.app`, team `Z44N5GDT9Q`, ARM64 executable.
- Archive AppleDouble metadata was merged with dot_clean; no source or app
  executable was modified. DMG mounting was denied, so the official app archive
  was used. Download/source-audit scratch directories were removed.

## Verification evidence

- Smoke: Alpine 3.22 returned `kiri-speedup-ok`, exit 0; subsequent `ps -a` was empty.
- Endpoint: API Platform.Name was Kiri and Kiri component version was 0.2.2.
  Docker's compatibility Version field is 27.5.1 and is not the Kiri release version.
- Shutdown: daemon exited, VM-stop log observed, socket removed, and no process
  held the QA VM disk open after cleanup.
- Cancellation: SIGTERM to the launcher during `alpine sleep 30` stopped the
  owned daemon/VM and removed the socket without a forced daemon kill. The guest
  stopped its workload after its shutdown grace period (exit 137).
- Production: process IDs and executable paths stayed unchanged; Docker config,
  context metadata, Conjet persisted runtime binding, LaunchAgent files, and
  resolver-file hashes matched before/after the final smoke and cancellation runs.
- Production Docker context remained conjet and its server responded as 29.1.3.
- Preflight failure tests: occupied router port and concurrent session lock were
  rejected before daemon startup; neither left a Docker socket.
- Python syntax, local documentation links, and git diff whitespace checks passed;
  graphify code graph was updated.
- No UI was changed or launched, so there is no meaningful screenshot target.
  JSON evidence and daemon logs provide runtime validation instead.

These checks establish the accepted data/context separation and session cleanup,
not a speed claim or proof of complete host filesystem confinement.

## Retention and removal

The installed app and managed test-data directory are intentionally retained for
future worker sessions. No persistent process or scheduled registration is created.
Temporary source-audit files are removed. To uninstall later, stop the launcher,
verify no QA processes remain, and remove only the task-owned app and test-data
directories. Review `~/.kiri` before removing anything there; never delete another
Kiri installation's settings or use a global Docker prune/uninstall command.

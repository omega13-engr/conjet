# Speedup environment status

## Official Kiri installation

Installed 2026-11-22 from the official libracoder/kiri v0.2.2 release:

- Local app: `.speedup/tools/kiri-0.2.2/Kiri.app` (ignored by Git).
- Source archive: `https://github.com/libracoder/kiri/releases/download/v0.2.2/Kiri-0.2.2-arm64.tar.gz`.
- SHA256 verified against official SHA256SUMS:
  `b08f568ed7dc95e4e1a09acb718daaf21019fb7aad96345c476ff5ed695d77fb`.
- `codesign --verify --deep --strict --verbose=2` passed.
- Signature identifier `dev.kiri.app`, team `Z44N5GDT9Q`; executable is ARM64.
- Archive AppleDouble metadata was merged with dot_clean before signature validation.
- Official DMG mounting was denied by the environment; the official app archive
  supplied the same release without mounting or running an installer.

No application setup, daemon, UI, startup service, shell modification, or global
Docker context was launched/installed. Docker context show returned `conjet`
before and after installation. The app bundle is installed, but runtime isolation
and benchmark readiness are NOT qualified.

## Startup blocker

Release v0.2.2 source (commit 686bffa5f38ba6ecc3d086c36ec7148cd7fb976a)
allows KIRI_DATA_DIR and KIRI_SOCKET overrides, but daemon::state_dir always
resolves beneath HOME to `.kiri`. This holds private settings and CA state.
Changing only data and socket paths does not fully scope the runtime to speedup.
The current execution instructions prohibit repurposing HOME. Do not work around
this by modifying or symlinking existing user state or changing the signed app's
bundle identity.

Normal setup can install a LaunchAgent, shell integration, and Docker integration.
Do not run setup or open the app through Finder. Even direct daemon startup needs
an isolation solution and review of DNS, domain ports, Finder mounts, updates,
and guest shared directories before use.

Required environment location: `/Volumes/ExternalSSD/dev_workspace/tmp`.
The user explicitly rejected creating a dedicated macOS test account. Keep the
unmodified official app and do not alter production state. Candidate layout:

```text
/Volumes/ExternalSSD/dev_workspace/tmp/conjet-speedup-<session>/
  kiri-data/
  kiri-state/       # requires a supported state-directory override
  docker-config/
  logs/
  evidence/
```

KIRI_DATA_DIR and KIRI_SOCKET alone cannot redirect all state. A private child
HOME would normally address HOME-relative paths, but current session instructions
prohibit overriding HOME. No such override has been executed. Qualification needs
a supported complete state-path override or revised environment permissions;
do not substitute an altered bundle identity or production-state symlinks.

Keep SPEED-000 incomplete until live isolation and cleanup pass. The
conjet-speedup candidate context and launcher remain pending. No benchmark ran.

## Removal

With no Kiri processes running, remove only the task-owned
`.speedup/tools/kiri-0.2.2` directory. No global uninstaller is needed because no
setup integration was run. Download, source-audit, and conversion scratch files
were removed after preserving this receipt.

## Follow-up isolation audit

The v0.2.2 guest configuration hardcodes host shares for `/Users`, `/Volumes`,
and `/private` in `crates/kiri/src/guest.rs::mac_share_dirs`. Data and socket
relocation alone therefore cannot establish complete host filesystem isolation.
A minimal sandbox-exec invocation succeeded, but confinement of Apple's VM
helper and guest virtiofs access has not been qualified. No Kiri daemon was run.

A same-account implementation path is a source build pinned to the official
release with narrowly scoped configuration additions: an explicit state root,
an explicit host-share allowlist restricted to the QA root, and disabled optional
host integrations. This is a modified competitor build and must be disclosed in
benchmark evidence. It is not interchangeable with an unmodified official binary
for claims. Implementing that competitor fork requires agreement on this changed
benchmark scope. The installed official app remains intact for reference.

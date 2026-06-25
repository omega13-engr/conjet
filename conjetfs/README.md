# ConjetFS

ConjetFS keeps source and project metadata host-authoritative while moving
dependency folders, package caches, database data, and build outputs into
native Linux storage.

The current MVP is host-driven and conservative:

- `conjet project init PATH` writes `.conjet/project.json` and a small
  `.conjetignore`.
- `conjet project attach PATH` creates or reuses a Conjet-owned Docker volume,
  stages host-authoritative files, and copies them into `/workspace` in that
  volume.
- `conjet sync push PATH` repeats the one-way host-to-VM sync.
- `conjet sync status PATH` reports whether host-authoritative files have
  changed or been removed since the last push.
- `conjet sync watch PATH` uses macOS FSEvents to trigger incremental pushes for
  development loops; `--poll --interval 1` keeps the conservative polling path
  available for fallback debugging.
- `conjet sync repair PATH` replays the host-authoritative view into the
  project volume and refreshes the sync manifest.
- `conjet sync export PATH... --to DEST --path PROJECT` explicitly copies
  selected generated artifacts out of the VM-native workspace.
- `PathClassifier` keeps `node_modules`, `vendor`, `target`, `.next`,
  `.turbo`, `.cache`, and similar churn in VM-native storage.
- Removed host-synced files are deleted from the VM workspace on the next push,
  but VM-native dependency/build paths are not synced back to macOS.
- Pushes are incremental after the first sync: the manifest stores path
  signatures, unchanged files are not recopied, and modified host files are the
  only files staged for the next `docker cp`.

This is not the final filesystem engine. It is the first measurable workflow
with a host-side FSEvents trigger. Guest-side inotify/fanotify replay,
content-addressed indexes, parallel delta transfer, and broader two-way
semantics are still future work. Artifact export is intentionally explicit so
build outputs and dependency churn do not wake macOS watchers or corrupt
host-side source state.

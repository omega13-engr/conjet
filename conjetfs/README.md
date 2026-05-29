# ConjetFS

ConjetFS keeps source and project metadata host-authoritative while moving
dependency folders, package caches, database data, and build outputs into
native Linux storage. The first implementation is the Swift `PathClassifier`
in `Sources/ConjetCore`; a Rust or Swift sync engine can be introduced behind
that policy boundary later.

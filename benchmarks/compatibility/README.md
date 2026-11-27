# Expanded Docker compatibility tests

See the [plan](../../docs/engineering/docker-compatibility-matrix-plan.md) and
[task board](../../docs/engineering/docker-compatibility-task-board.md).

`matrix.json` maps 88 initially UNTESTED contracts to real Python test methods.
Methods deliberately fail until implemented; they are not compatibility evidence.
`run.py --check` validates mapping only. `test_inventory.py` tests the inventory
and fail-closed result accounting. `run.py --profile all` runs every contract and
rejects skips, expected failures and incomplete runs. It does not yet validate
runtime evidence provenance; the release gate must add that before publication.

Run with `PYTHONDONTWRITEBYTECODE=1`; keep generated artifacts on ExternalSSD.
Never run runtime fixtures against a default or production Docker endpoint.

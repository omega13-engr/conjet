# Expanded Docker compatibility tests

See the [plan](../../docs/engineering/docker-compatibility-matrix-plan.md) and
[task board](../../docs/engineering/docker-compatibility-task-board.md).

`matrix.json` maps 88 initially UNTESTED contracts to real Python test methods.
Methods deliberately fail until implemented; they are not compatibility evidence.
`run.py --check` validates the mapping without accessing an engine.

Run the lanes serially. The reference launcher takes the pinned aarch64 Debian
12 cloud disk and Docker 29.10.1 Linux aarch64 archive. The candidate launcher
takes the signed app and explicit Docker, Buildx and Compose executables.
Use new receipt paths under ExternalSSD.

```sh
python3 -B benchmarks/compatibility-reference.py --disk "$reference_disk" \
  --docker-archive "$reference_archive" --profile all --evidence "$reference_receipt"
python3 -B benchmarks/native-fresh-buildx.py --app "$app" --docker "$docker" \
  --buildx "$buildx" --compose "$compose" --compatibility-profile all \
  --evidence "$candidate_receipt"
python3 -B benchmarks/compatibility/run.py --profile all \
  --candidate "$candidate_receipt" --reference "$reference_receipt" --evidence "$comparison"
```

Both launchers record failed cases before stopping their own runtime. The comparison
requires the expected cases and fixture hashes, distinct live endpoint identities,
engine and kernel hashes, verified launcher cleanup and matching observations.
Each fixture uses `self.compatibility.request()` for bounded Docker API calls
and records its normalized observation with `self.compatibility.record()`.
Fixture code owns resource removal. The runner checks that container, image,
network and volume inventories return to their starting state. Cases exercising
other resources must verify those explicitly before recording observations.

The launchers also accept `--direct-egress-ip` in place of a profile. Give both
lanes the same current public IPv4 address for `example.com`. The diagnostic
runs the same pinned Alpine image on `bridge` and `none`. It records DNS
resolution and direct HTTP by address separately, with an in-container exit
marker for each observation. Its receipt does not qualify TLS or proxy behavior.

The pinned Engine and Compose schema sources are in `schema-sources.json`.
Download those files to a private scratch directory and pass that directory to
`schema_inventory.py --inputs` with a new `--evidence` path. The inventory uses
`yq` to parse the Engine YAML and fails while any discovered field lacks a planned
case or documented platform exclusion. Runtime compatibility requires a passing
fixture for each in-scope contract. Engine rows include response statuses and
headers. The receipt lists the operations that use each inline or referenced
field so shared fields can be mapped to the correct tests. These associations
do not satisfy any coverage gate by themselves.

Run with `PYTHONDONTWRITEBYTECODE=1`; keep generated artifacts on ExternalSSD.
Never run runtime fixtures against a default or production Docker endpoint.

DC-004 uses stock docker-py 7.1.0 and docker-java 3.7.1. Run both
launchers with Python from an ExternalSSD virtual environment containing
`docker==7.1.0` and Java 11 or later on `PATH`. Resolve the Java fixture's
dependencies into a scratch Maven repository with the classpath beside it.

```sh
mvn -f benchmarks/compatibility/clients/java/pom.xml \
  -Dmaven.repo.local="$sdk_root/m2" -Dmdep.outputFile="$sdk_root/classpath" \
  org.apache.maven.plugins:maven-dependency-plugin:3.9.0:build-classpath
export CONJET_COMPAT_DOCKER_JAVA_CLASSPATH="$sdk_root/classpath"
```

Each SDK receives only the authenticated lane's Unix socket and a private,
empty Docker configuration directory.

DC-005 uses Node.js with Testcontainers 12.2.2. Install it in the private
scratch directory and point the harness to that installation.

```sh
npm install --prefix "$sdk_root/node" --cache "$sdk_root/npm-cache" \
  --ignore-scripts --save-exact testcontainers@12.2.2
export CONJET_COMPAT_TESTCONTAINERS_PACKAGE="$sdk_root/node/node_modules/testcontainers/package.json"
```

The fixture limits Node socket connections to the verified lane endpoint.
The harness owns cleanup of the named containers and network.

# Homebrew Tap

Conjet is installed through the Homebrew tap:

```sh
brew tap omega13-engr/conjet
brew install conjet
```

Homebrew resolves that tap name to the GitHub repository
`omega13-engr/homebrew-conjet`.

## Release Flow

Conjet uses semantic version tags for the production CLI/runtime:

```text
conjet-vX.Y.Z
```

When `.github/workflows/release-conjet.yml` runs, it:

- builds and tests the Swift package,
- creates release archives for `conjet` and `conjetd`,
- publishes a GitHub release,
- renders a release formula with the source archive SHA256,
- uploads that formula as a release asset,
- updates `omega13-engr/homebrew-conjet` when `HOMEBREW_TAP_TOKEN` is configured.

The checked-in `Formula/conjet.rb` is the source formula. The release workflow
renders the exact formula that should be published to the tap for each version.

## Developer Builds

Install the latest source build from the tap with:

```sh
brew install --HEAD conjet
```

The benchmark package is intentionally not installed by Homebrew. Run benchmarks
from a source checkout:

```sh
swift run --package-path benchmarks conjet-bench --help
```

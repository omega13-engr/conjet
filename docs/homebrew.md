# Homebrew Tap

Conjet is installed through the Homebrew tap:

```sh
brew tap omega13-engr/conjet https://github.com/omega13-engr/conjet.git
brew install conjet
```

The explicit URL keeps the tap pointed at the Conjet repository. The formula
installs the `conjet` and `conjetd` command-line tools and keeps a
keg-local copy of `Conjet.app` under:

```sh
open "$(brew --prefix conjet)/Applications/Conjet.app"
```

Install the visible macOS app into `/Applications` with the cask:

```sh
brew install --cask omega13-engr/conjet/conjet
```

The formula and cask can be installed together: the formula owns Homebrew's CLI
symlinks, and the cask owns `/Applications/Conjet.app`.

## Release Flow

Conjet uses semantic version tags for the production CLI/runtime:

```text
conjet-vX.Y.Z
```

When `.github/workflows/release-conjet.yml` runs, it:

- builds and tests the Swift package,
- signs `Conjet.app`, `conjet`, `conjetd`, and the bundled Conjet Core VMM,
- creates and notarizes the release DMG,
- publishes a GitHub release,
- renders a binary Homebrew formula with the stapled DMG SHA256,
- renders a Homebrew cask for `/Applications/Conjet.app`,
- uploads the formula and cask as release assets,
- updates `Formula/conjet.rb` and `Casks/conjet.rb` in the source repository.

The pushed `conjet-vX.Y.Z` tag is the source of truth for the release version.

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

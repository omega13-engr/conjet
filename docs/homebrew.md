# Homebrew Tap

Conjet is installed through the Homebrew tap:

```sh
brew tap omega13-engr/conjet https://github.com/omega13-engr/conjet.git
brew install conjet
```

The explicit URL keeps the tap pointed at the Conjet repository.

## Release Flow

Conjet uses semantic version tags for the production CLI/runtime:

```text
conjet-vX.Y.Z
```

When `.github/workflows/release-conjet.yml` runs, it:

- builds and tests the Swift package,
- signs `Conjet.app`, `conjet`, and `conjetd`,
- creates and notarizes the release DMG,
- publishes a GitHub release,
- renders a binary Homebrew formula with the stapled DMG SHA256,
- uploads that formula as a release asset,
- updates `Formula/conjet.rb` in the source repository.

The pushed `conjet-vX.Y.Z` tag is the source of truth for the release version.

The formula installs `Conjet.app` under the formula prefix and symlinks the
bundled command-line tools into Homebrew's `bin` directory. Open the app with:

```sh
open "$(brew --prefix conjet)/Applications/Conjet.app"
```

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

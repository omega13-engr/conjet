# Homebrew Tap

The repository includes a formula at `Formula/conjet.rb` for a tap named
`omega13-engr/conjet`.

```sh
brew tap omega13-engr/conjet
brew install conjet
```

The formula builds the production SwiftPM products only:

- `conjet`
- `conjetd`

The standalone benchmark package is intentionally not installed by the formula.
Developers should run benchmarks from a source checkout:

```sh
swift run --package-path benchmarks conjet-bench --help
```

## Release Maintenance

The current formula points at the `main` branch and pins `version "0.1.0"` for
local tap testing. For production releases, replace the Git branch URL with a
versioned archive and SHA256:

```ruby
url "https://github.com/omega13-engr/conjet/archive/refs/tags/v0.1.0.tar.gz"
sha256 "<release archive sha256>"
```

Keep the formula scoped to the production runtime. Benchmark reports, raw
results, and research harnesses belong in `benchmarks/`.

The formula applies an ad-hoc signature with the local Virtualization.framework
development entitlements after installation so VM commands can run from the
installed binaries during local tap testing.

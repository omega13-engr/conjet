#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: render-homebrew-cask.sh VERSION DMG_SHA256 [SOURCE_REPOSITORY] [ARTIFACT_ARCH]}"
asset_sha256="${2:?usage: render-homebrew-cask.sh VERSION DMG_SHA256 [SOURCE_REPOSITORY] [ARTIFACT_ARCH]}"
source_repository="${3:-omega13-engr/conjet}"
artifact_arch="${4:-arm64}"

if ! printf '%s\n' "${version}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "invalid semantic version: ${version}" >&2
    exit 1
fi

if [ "${artifact_arch}" != "arm64" ]; then
    echo "unsupported Homebrew cask artifact architecture: ${artifact_arch}" >&2
    exit 1
fi

cat <<RUBY
cask "conjet" do
  version "${version}"
  sha256 "${asset_sha256}"

  url "https://github.com/${source_repository}/releases/download/conjet-v#{version}/conjet-#{version}-macos-${artifact_arch}.dmg"
  name "Conjet"
  desc "Container runtime and management interface for developers"
  homepage "https://github.com/${source_repository}"

  livecheck do
    url "https://github.com/${source_repository}/releases"
    regex(/^conjet-v(\\d+\\.\\d+\\.\\d+)$/i)
  end

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "Conjet.app"

  uninstall quit: [
    "dev.conjet.app",
    "dev.conjet.app.menubar",
  ]

  zap trash: [
    "~/Library/Application Support/Conjet",
    "~/Library/Caches/dev.conjet.app",
    "~/Library/Caches/dev.conjet.app.menubar",
    "~/Library/HTTPStorages/dev.conjet.app",
    "~/Library/Preferences/dev.conjet.app.menubar.plist",
    "~/Library/Preferences/dev.conjet.app.plist",
    "~/Library/Saved Application State/dev.conjet.app.savedState",
  ]

  caveats <<~EOS
    This cask installs Conjet.app into /Applications. The formula remains the
    Homebrew-managed install path for the conjet and conjetd command-line tools:
      brew install ${source_repository}/conjet

    Current early releases are ad-hoc signed and not notarized; use right-click
    Open if Gatekeeper blocks the first launch.
  EOS
end
RUBY

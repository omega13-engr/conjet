#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: render-homebrew-formula.sh VERSION SOURCE_SHA256 [SOURCE_REPOSITORY]}"
source_sha256="${2:?usage: render-homebrew-formula.sh VERSION SOURCE_SHA256 [SOURCE_REPOSITORY]}"
source_repository="${3:-zdxsector/conjet}"
tag="conjet-v${version}"

if ! printf '%s\n' "${version}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "invalid semantic version: ${version}" >&2
    exit 1
fi

cat <<RUBY
class Conjet < Formula
  desc "Super Sonic Speed containers for macOS developers"
  homepage "https://github.com/${source_repository}"
  url "https://github.com/${source_repository}/archive/refs/tags/${tag}.tar.gz"
  sha256 "${source_sha256}"
  version "${version}"
  head "https://github.com/${source_repository}.git", branch: "main"

  livecheck do
    url "https://github.com/${source_repository}/releases"
    regex(/^conjet-v(\\d+\\.\\d+\\.\\d+)$/i)
  end

  depends_on xcode: ["15.0", :build]
  depends_on macos: :sonoma

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "conjet"
    system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "conjetd"

    bin.install ".build/release/conjet"
    bin.install ".build/release/conjetd"

    entitlements = buildpath/"build-support/conjet-debug.entitlements"
    system "codesign", "--force", "--sign", "-", "--entitlements", entitlements, bin/"conjet"
    system "codesign", "--force", "--sign", "-", "--entitlements", entitlements, bin/"conjetd"
  end

  test do
    assert_match "Conjet manages", shell_output("#{bin}/conjet --help")
  end
end
RUBY

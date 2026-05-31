#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: render-homebrew-formula.sh VERSION ASSET_SHA256 [SOURCE_REPOSITORY] [ARTIFACT_ARCH]}"
asset_sha256="${2:?usage: render-homebrew-formula.sh VERSION ASSET_SHA256 [SOURCE_REPOSITORY] [ARTIFACT_ARCH]}"
source_repository="${3:-omega13-engr/conjet}"
artifact_arch="${4:-arm64}"
tag="conjet-v${version}"
asset_name="conjet-${version}-macos-${artifact_arch}.tar.gz"

if ! printf '%s\n' "${version}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "invalid semantic version: ${version}" >&2
    exit 1
fi

if [ "${artifact_arch}" != "arm64" ]; then
    echo "unsupported Homebrew artifact architecture: ${artifact_arch}" >&2
    exit 1
fi

cat <<RUBY
class Conjet < Formula
  desc "Super Sonic Speed containers for macOS developers"
  homepage "https://github.com/${source_repository}"
  url "https://github.com/${source_repository}/releases/download/${tag}/${asset_name}"
  sha256 "${asset_sha256}"
  version "${version}"
  head "https://github.com/${source_repository}.git", branch: "main"

  livecheck do
    url "https://github.com/${source_repository}/releases"
    regex(/^conjet-v(\\d+\\.\\d+\\.\\d+)$/i)
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    if build.head?
      system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "conjet"
      system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "conjetd"

      bin.install ".build/release/conjet"
      bin.install ".build/release/conjetd"

      entitlements = buildpath/"build-support/conjet-debug.entitlements"
      system "codesign", "--force", "--sign", "-", "--entitlements", entitlements, bin/"conjet"
      system "codesign", "--force", "--sign", "-", "--entitlements", entitlements, bin/"conjetd"
    else
      conjet = Dir["**/conjet"].find { |path| File.file?(path) }
      conjetd = Dir["**/conjetd"].find { |path| File.file?(path) }
      bin.install conjet => "conjet"
      bin.install conjetd => "conjetd"
    end
  end

  test do
    assert_match "Conjet manages", shell_output("#{bin}/conjet --help")
  end
end
RUBY

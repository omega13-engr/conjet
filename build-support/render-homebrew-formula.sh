#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: render-homebrew-formula.sh VERSION DMG_SHA256 [SOURCE_REPOSITORY] [ARTIFACT_ARCH]}"
asset_sha256="${2:?usage: render-homebrew-formula.sh VERSION DMG_SHA256 [SOURCE_REPOSITORY] [ARTIFACT_ARCH]}"
source_repository="${3:-omega13-engr/conjet}"
artifact_arch="${4:-arm64}"
tag="conjet-v${version}"
asset_name="conjet-${version}-macos-${artifact_arch}.dmg"

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
      system "build-support/stage-macos-app.sh",
        "--configuration", "release",
        "--version", version.to_s,
        "--dist-dir", buildpath/"dist",
        "--signing-identity", "-",
        "--entitlements", buildpath/"build-support/conjet-release.entitlements",
        "--disable-sandbox"
      install_app_bundle buildpath/"dist/Conjet.app"
    else
      app_bundle = Dir["**/Conjet.app"].find { |path| File.directory?(path) }
      odie "Conjet.app is missing from the release DMG" if app_bundle.nil?

      install_app_bundle app_bundle
    end
  end

  def install_app_bundle(app_bundle)
    appdir = prefix/"Applications"
    appdir.install app_bundle

    tools = appdir/"Conjet.app/Contents/Resources/ConjetTools"
    bin.install_symlink tools/"conjet" => "conjet"
    bin.install_symlink tools/"conjetd" => "conjetd"
  end

  test do
    assert_path_exists prefix/"Applications/Conjet.app/Contents/MacOS/Conjet"
    assert_match "Conjet manages", shell_output("#{bin}/conjet --help")
  end
end
RUBY

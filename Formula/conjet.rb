class Conjet < Formula
  desc "Super Sonic Speed containers for macOS developers"
  homepage "https://github.com/omega13-engr/conjet"
  url "https://github.com/omega13-engr/conjet/releases/download/conjet-v0.3.6/conjet-0.3.6-macos-arm64.dmg"
  version "0.3.6"
  sha256 "dee0a0dc7c011bb185f2b9fcd860877023f59623860e55359f198d293337cf70"
  head "https://github.com/omega13-engr/conjet.git", branch: "main"

  livecheck do
    url "https://github.com/omega13-engr/conjet/releases"
    regex(/^conjet-v(\d+\.\d+\.\d+)$/i)
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
    strip_extended_attributes(appdir/"Conjet.app")

    tools = appdir/"Conjet.app/Contents/Resources/ConjetTools"
    bin.install_symlink tools/"conjet" => "conjet"
    bin.install_symlink tools/"conjetd" => "conjetd"
  end

  def post_install
    strip_extended_attributes(prefix/"Applications/Conjet.app")
  end

  def strip_extended_attributes(path)
    return unless path.directory?

    system "/usr/bin/xattr", "-cr", path
  end

  def caveats
    <<~EOS
      The formula installs Homebrew-managed CLI tools and keeps Conjet.app inside the keg:
        #{prefix}/Applications/Conjet.app

      To install Conjet.app into /Applications, use the cask:
        brew install --cask omega13-engr/conjet/conjet
    EOS
  end

  test do
    assert_path_exists prefix/"Applications/Conjet.app/Contents/MacOS/Conjet"
    assert_match "Conjet manages", shell_output("#{bin}/conjet --help")
  end
end

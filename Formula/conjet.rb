class Conjet < Formula
  desc "Super Sonic Speed containers for macOS developers"
  homepage "https://github.com/omega13-engr/conjet"
  url "https://github.com/omega13-engr/conjet/releases/download/conjet-v1.1.3/conjet-1.1.3-macos-arm64.dmg"
  version "1.1.3"
  sha256 "97981222182468300e33190aa5a386730528b88dfe92c516346a202d3d5b1c97"
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

      For the standard one-step install of Conjet.app plus conjet/conjetd, use the cask:
        brew install --cask omega13-engr/conjet/conjet

      If CONJET_HOME points under /Volumes, grant Removable Volumes or Full Disk
      Access to your terminal app and Conjet.app in System Settings.
    EOS
  end

  test do
    assert_path_exists prefix/"Applications/Conjet.app/Contents/MacOS/Conjet"
    assert_match "Conjet manages", shell_output("#{bin}/conjet --help")
  end
end

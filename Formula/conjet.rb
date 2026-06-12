class Conjet < Formula
  desc "Super Sonic Speed containers for macOS developers"
  homepage "https://github.com/omega13-engr/conjet"
  url "https://github.com/omega13-engr/conjet/releases/download/conjet-v0.3.4/conjet-0.3.4-macos-arm64.tar.gz"
  sha256 "1602d989b68efb7765c1a8dfe5ea110f3a6fcda6541d9a9c095991fa3265de87"
  version "0.3.4"
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

      if app_bundle
        install_app_bundle app_bundle
      else
        conjet = Dir["**/conjet"].find { |path| File.file?(path) }
        conjetd = Dir["**/conjetd"].find { |path| File.file?(path) }
        bin.install conjet => "conjet"
        bin.install conjetd => "conjetd"
      end
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
    assert_match "Conjet manages", shell_output("#{bin}/conjet --help")
  end
end

class Conjet < Formula
  desc "Super Sonic Speed containers for macOS developers"
  homepage "https://github.com/omega13-engr/conjet"
  url "https://github.com/omega13-engr/conjet/releases/download/conjet-v0.2.1/conjet-0.2.1-macos-arm64.tar.gz"
  sha256 "8a50f01a9faad4e0f6d28b18893633f6debb4ab3c6580060dddf7b39ef9839a0"
  version "0.2.1"
  head "https://github.com/omega13-engr/conjet.git", branch: "main"

  livecheck do
    url "https://github.com/omega13-engr/conjet/releases"
    regex(/^conjet-v(\d+\.\d+\.\d+)$/i)
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

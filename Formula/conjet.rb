class Conjet < Formula
  desc "Super Sonic Speed containers for macOS developers"
  homepage "https://github.com/omega13-engr/conjet"
  url "https://github.com/omega13-engr/conjet.git", tag: "conjet-v0.1.0"
  version "0.1.0"
  head "https://github.com/omega13-engr/conjet.git", branch: "main"

  livecheck do
    url "https://github.com/omega13-engr/conjet/releases"
    regex(/^conjet-v(\d+\.\d+\.\d+)$/i)
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

class Conjet < Formula
  desc "Lightweight macOS container runtime with synchronized Linux workspaces"
  homepage "https://github.com/omega13-engr/conjet"
  url "https://github.com/omega13-engr/conjet.git", branch: "main"
  version "0.1.0"

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

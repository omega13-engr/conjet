cask "conjet" do
  version "0.3.7"
  sha256 "d98fbace3d643e05d66818314b5b9f64d98b80da72dba66b1e3447838e65c63e"

  url "https://github.com/omega13-engr/conjet/releases/download/conjet-v#{version}/conjet-#{version}-macos-arm64.dmg"
  name "Conjet"
  desc "Container runtime and management interface for developers"
  homepage "https://github.com/omega13-engr/conjet"

  livecheck do
    url "https://github.com/omega13-engr/conjet/releases"
    regex(/^conjet-v(\d+\.\d+\.\d+)$/i)
  end

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "Conjet.app"

  postflight do
    app_path = "#{appdir}/Conjet.app"
    system_command "/usr/bin/xattr", args: ["-cr", app_path] if File.directory?(app_path)
  end

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
      brew install omega13-engr/conjet/conjet

    Current early releases are ad-hoc signed and not notarized; use right-click
    Open if Gatekeeper blocks the first launch.
  EOS
end

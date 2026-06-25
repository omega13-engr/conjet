cask "conjet" do
  version "1.0.1"
  sha256 "78873db310d32576cc537838e96d8cfb5a9b34e91469ac5c02217dadd1a23769"

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
  binary "bin/conjet"
  binary "bin/Conjet Core"

  postflight do
    [
      "#{appdir}/Conjet.app",
      "#{staged_path}/bin/conjet",
      "#{staged_path}/bin/Conjet Core",
    ].each do |path|
      system_command "/usr/bin/xattr", args: ["-cr", path] if File.exist?(path)
    end
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
    This cask installs Conjet.app into /Applications and links the bundled
    conjet and Conjet Core command-line tools into Homebrew's bin directory.

    If CONJET_HOME points under /Volumes, grant Removable Volumes or Full Disk
    Access to your terminal app and Conjet.app in System Settings.

    Current early releases are ad-hoc signed and not notarized; use right-click
    Open if Gatekeeper blocks the first launch.
  EOS
end

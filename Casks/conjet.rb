cask "conjet" do
  version "1.1.17"
  sha256 "8b9ed176dba899014fc372b4b83e0d3abf74f298777c16fd88eb24b99acf45dd"

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
  binary "bin/conjetd"

  postflight do
    [
      "#{appdir}/Conjet.app",
      "#{staged_path}/bin/conjet",
      "#{staged_path}/bin/conjetd",
      "#{staged_path}/bin/ConjetCoreVMM",
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
    conjet and conjetd command-line tools into Homebrew's bin directory.

    If CONJET_HOME points under /Volumes, grant Removable Volumes or Full Disk
    Access to your terminal app and Conjet.app in System Settings.

    Current early releases are ad-hoc signed and not notarized; use right-click
    Open if Gatekeeper blocks the first launch.
  EOS
end

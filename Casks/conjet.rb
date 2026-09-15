cask "conjet" do
  version "3.0.0"
  sha256 "abd9d29724920f957a13ac5277b2458637ee6ad89b66e45004b30c96b29b1eb6"

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

  postflight_steps do
    if_path_exists "Conjet.app", base: :appdir do
      run "/usr/bin/xattr", args: ["-cr", "{{appdir}}/Conjet.app"]
    end
    if_path_exists "bin/conjet" do
      run "/usr/bin/xattr", args: ["-cr", "{{staged_path}}/bin/conjet"]
    end
    if_path_exists "bin/conjetd" do
      run "/usr/bin/xattr", args: ["-cr", "{{staged_path}}/bin/conjetd"]
    end
    if_path_exists "bin/ConjetCoreVMM" do
      run "/usr/bin/xattr", args: ["-cr", "{{staged_path}}/bin/ConjetCoreVMM"]
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

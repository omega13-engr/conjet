#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift test --filter ConjetAppCoreTests
./script/build_and_run.sh --verify
test -f "$ROOT_DIR/Sources/ConjetApp/Resources/ConjetAppIcon.png"
test ! -f "$ROOT_DIR/ConjetAppIcon.png"
test -f "$ROOT_DIR/Sources/ConjetApp/Resources/ConjetMenuBarIcon.png"
test ! -f "$ROOT_DIR/ConjetMenuBarIcon.png"
test -f "$ROOT_DIR/dist/Conjet.app/Contents/Resources/AppIcon.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ROOT_DIR/dist/Conjet.app/Contents/Info.plist")" = "AppIcon"
test -f "$ROOT_DIR/dist/Conjet.app/Contents/Resources/MenuBarIcon.png"
test -x "$ROOT_DIR/dist/Conjet.app/Contents/Resources/ConjetTools/conjet"
test -x "$ROOT_DIR/dist/Conjet.app/Contents/Resources/ConjetTools/conjetd"
sleep 1
pkill -x Conjet >/dev/null 2>&1 || true

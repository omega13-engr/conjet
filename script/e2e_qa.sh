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
test -d "$ROOT_DIR/dist/Conjet.app/Contents/Library/LoginItems/Conjet Menu Bar.app"
test -x "$ROOT_DIR/dist/Conjet.app/Contents/Library/LoginItems/Conjet Menu Bar.app/Contents/MacOS/Conjet Menu Bar"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT_DIR/dist/Conjet.app/Contents/Library/LoginItems/Conjet Menu Bar.app/Contents/Info.plist")" = "dev.conjet.app.menubar"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$ROOT_DIR/dist/Conjet.app/Contents/Library/LoginItems/Conjet Menu Bar.app/Contents/Info.plist")" = "true"
codesign --verify --deep --strict "$ROOT_DIR/dist/Conjet.app"
codesign -dvvv --entitlements :- "$ROOT_DIR/dist/Conjet.app/Contents/Resources/ConjetTools/conjetd" >/dev/null 2>&1
sleep 1
pkill -x Conjet >/dev/null 2>&1 || true
pkill -x "Conjet Menu Bar" >/dev/null 2>&1 || true

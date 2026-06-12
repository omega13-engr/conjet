#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Conjet"
PRODUCT_NAME="ConjetApp"
APP_BUNDLE_ID="dev.conjet.app"
HELPER_NAME="Conjet Menu Bar"
HELPER_BUNDLE_ID="dev.conjet.app.menubar"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_TOOLS="$APP_RESOURCES/ConjetTools"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
LOGIN_ITEMS_DIR="$APP_CONTENTS/Library/LoginItems"
HELPER_BUNDLE="$LOGIN_ITEMS_DIR/$HELPER_NAME.app"
HELPER_CONTENTS="$HELPER_BUNDLE/Contents"
HELPER_MACOS="$HELPER_CONTENTS/MacOS"
HELPER_RESOURCES="$HELPER_CONTENTS/Resources"
HELPER_TOOLS="$HELPER_RESOURCES/ConjetTools"
HELPER_BINARY="$HELPER_MACOS/$HELPER_NAME"
HELPER_INFO_PLIST="$HELPER_CONTENTS/Info.plist"
ENTITLEMENTS="$ROOT_DIR/build-support/conjet-debug.entitlements"

cd "$ROOT_DIR"

if [ "$MODE" != "--stage" ] && [ "$MODE" != "stage" ]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

swift build --product "$PRODUCT_NAME"
swift build --product conjet
swift build --product conjetd
BUILD_DIR="$(swift build --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_TOOLS" "$HELPER_MACOS" "$HELPER_TOOLS"
cp "$BUILD_DIR/$PRODUCT_NAME" "$APP_BINARY"
cp "$BUILD_DIR/conjet" "$APP_TOOLS/conjet"
cp "$BUILD_DIR/conjetd" "$APP_TOOLS/conjetd"
cp "$ROOT_DIR/Sources/ConjetApp/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
cp "$ROOT_DIR/Sources/ConjetApp/Resources/MenuBarIcon.png" "$APP_RESOURCES/MenuBarIcon.png"
cp "$BUILD_DIR/$PRODUCT_NAME" "$HELPER_BINARY"
cp "$BUILD_DIR/conjet" "$HELPER_TOOLS/conjet"
cp "$BUILD_DIR/conjetd" "$HELPER_TOOLS/conjetd"
cp "$ROOT_DIR/Sources/ConjetApp/Resources/AppIcon.icns" "$HELPER_RESOURCES/AppIcon.icns"
cp "$ROOT_DIR/Sources/ConjetApp/Resources/MenuBarIcon.png" "$HELPER_RESOURCES/MenuBarIcon.png"
chmod +x "$APP_BINARY" "$APP_TOOLS/conjet" "$APP_TOOLS/conjetd" "$HELPER_BINARY" "$HELPER_TOOLS/conjet" "$HELPER_TOOLS/conjetd"

for resource_bundle in "$BUILD_DIR"/*ConjetApp*.resources "$BUILD_DIR"/*conjet_ConjetApp.resources; do
  if [ -d "$resource_bundle" ]; then
    rm -rf "$APP_BUNDLE/$(basename "$resource_bundle")"
    cp -R "$resource_bundle" "$APP_BUNDLE/$(basename "$resource_bundle")"
  fi
done

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$APP_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

cat >"$HELPER_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$HELPER_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$HELPER_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$HELPER_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$HELPER_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_BINARY"
codesign --force --sign - "$HELPER_BINARY"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_TOOLS/conjet"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_TOOLS/conjetd"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$HELPER_TOOLS/conjet"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$HELPER_TOOLS/conjetd"
codesign --force --sign - "$HELPER_BUNDLE"
codesign --force --sign - "$APP_BUNDLE"

open_app() {
  /usr/bin/open "$APP_BUNDLE"
}

open_app_without_background_registration() {
  /usr/bin/open --env CONJET_DISABLE_BACKGROUND_SERVICE_REGISTRATION=1 "$APP_BUNDLE"
}

case "$MODE" in
  --stage|stage)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$APP_BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app_without_background_registration
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--stage|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

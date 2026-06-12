#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: stage-macos-app.sh [options]

Options:
  --configuration debug|release    Swift build configuration (default: release)
  --version VERSION                CFBundleShortVersionString value
  --dist-dir DIR                   Destination directory for Conjet.app (default: dist)
  --signing-identity ID            codesign identity; use "-" for ad-hoc (default: -)
  --entitlements PATH              Entitlements for conjet/conjetd
  --disable-sandbox                Pass --disable-sandbox to swift build
USAGE
}

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIGURATION="release"
APP_VERSION="$(cat "$ROOT_DIR/VERSION" 2>/dev/null || printf '0.0.0')"
DIST_DIR="$ROOT_DIR/dist"
SIGNING_IDENTITY="${CONJET_CODE_SIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT_DIR/build-support/conjet-release.entitlements"
DISABLE_SANDBOX=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --configuration)
      CONFIGURATION="${2:?missing value for --configuration}"
      shift 2
      ;;
    --version)
      APP_VERSION="${2:?missing value for --version}"
      shift 2
      ;;
    --dist-dir)
      DIST_DIR="${2:?missing value for --dist-dir}"
      shift 2
      ;;
    --signing-identity)
      SIGNING_IDENTITY="${2:?missing value for --signing-identity}"
      shift 2
      ;;
    --entitlements)
      ENTITLEMENTS="${2:?missing value for --entitlements}"
      shift 2
      ;;
    --disable-sandbox)
      DISABLE_SANDBOX=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$CONFIGURATION" in
  debug|release) ;;
  *)
    echo "unsupported configuration: $CONFIGURATION" >&2
    exit 2
    ;;
esac

if ! printf '%s\n' "$APP_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
  echo "invalid app version: $APP_VERSION" >&2
  exit 2
fi

APP_NAME="Conjet"
PRODUCT_NAME="ConjetApp"
APP_BUNDLE_ID="dev.conjet.app"
HELPER_NAME="Conjet Menu Bar"
HELPER_BUNDLE_ID="dev.conjet.app.menubar"
MIN_SYSTEM_VERSION="14.0"

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

if [ ! -f "$ENTITLEMENTS" ]; then
  echo "entitlements file does not exist: $ENTITLEMENTS" >&2
  exit 1
fi

cd "$ROOT_DIR"

swift_build_args=("-c" "$CONFIGURATION")
if [ "$DISABLE_SANDBOX" -eq 1 ]; then
  swift_build_args+=("--disable-sandbox")
fi

swift build "${swift_build_args[@]}" --product "$PRODUCT_NAME"
swift build "${swift_build_args[@]}" --product conjet
swift build "${swift_build_args[@]}" --product conjetd
BUILD_DIR="$(swift build "${swift_build_args[@]}" --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_TOOLS" "$HELPER_MACOS" "$HELPER_TOOLS"

/usr/bin/ditto "$BUILD_DIR/$PRODUCT_NAME" "$APP_BINARY"
/usr/bin/ditto "$BUILD_DIR/conjet" "$APP_TOOLS/conjet"
/usr/bin/ditto "$BUILD_DIR/conjetd" "$APP_TOOLS/conjetd"
/usr/bin/ditto "$BUILD_DIR/$PRODUCT_NAME" "$HELPER_BINARY"
/usr/bin/ditto "$BUILD_DIR/conjet" "$HELPER_TOOLS/conjet"
/usr/bin/ditto "$BUILD_DIR/conjetd" "$HELPER_TOOLS/conjetd"

/usr/bin/ditto "$ROOT_DIR/Sources/ConjetApp/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
/usr/bin/ditto "$ROOT_DIR/Sources/ConjetApp/Resources/MenuBarIcon.png" "$APP_RESOURCES/MenuBarIcon.png"
/usr/bin/ditto "$ROOT_DIR/Sources/ConjetApp/Resources/AppIcon.icns" "$HELPER_RESOURCES/AppIcon.icns"
/usr/bin/ditto "$ROOT_DIR/Sources/ConjetApp/Resources/MenuBarIcon.png" "$HELPER_RESOURCES/MenuBarIcon.png"
chmod +x "$APP_BINARY" "$APP_TOOLS/conjet" "$APP_TOOLS/conjetd" "$HELPER_BINARY" "$HELPER_TOOLS/conjet" "$HELPER_TOOLS/conjetd"

shopt -s nullglob
for resource_bundle in "$BUILD_DIR"/*ConjetApp*.resources "$BUILD_DIR"/*conjet_ConjetApp.resources; do
  if [ -d "$resource_bundle" ]; then
    rm -rf "$APP_RESOURCES/$(basename "$resource_bundle")" "$HELPER_RESOURCES/$(basename "$resource_bundle")"
    /usr/bin/ditto "$resource_bundle" "$APP_RESOURCES/$(basename "$resource_bundle")"
    /usr/bin/ditto "$resource_bundle" "$HELPER_RESOURCES/$(basename "$resource_bundle")"
  fi
done
shopt -u nullglob

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$APP_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
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
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$HELPER_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$HELPER_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$HELPER_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$HELPER_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
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

codesign_base=(--force --sign "$SIGNING_IDENTITY" --options runtime)
if [ "$SIGNING_IDENTITY" != "-" ]; then
  codesign_base+=(--timestamp)
fi

codesign_tool() {
  /usr/bin/codesign "${codesign_base[@]}" --entitlements "$ENTITLEMENTS" "$1"
}

codesign_plain() {
  /usr/bin/codesign "${codesign_base[@]}" "$1"
}

codesign_tool "$HELPER_TOOLS/conjet"
codesign_tool "$HELPER_TOOLS/conjetd"
codesign_plain "$HELPER_BINARY"
codesign_plain "$HELPER_BUNDLE"
codesign_tool "$APP_TOOLS/conjet"
codesign_tool "$APP_TOOLS/conjetd"
codesign_plain "$APP_BINARY"
codesign_plain "$APP_BUNDLE"

/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HELPER_INFO_PLIST" >/dev/null

printf '%s\n' "$APP_BUNDLE"

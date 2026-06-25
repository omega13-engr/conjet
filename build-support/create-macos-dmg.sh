#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: create-macos-dmg.sh --version VERSION [options]

Options:
  --version VERSION       Release version without conjet-v prefix
  --dist-dir DIR          Directory containing Conjet.app (default: dist)
  --arch ARCH             Artifact architecture (default: uname -m)
  --app PATH              App bundle to package (default: DIST_DIR/Conjet.app)
USAGE
}

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION=""
DIST_DIR="$ROOT_DIR/dist"
ARCH="$(uname -m)"
APP_BUNDLE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      VERSION="${2:?missing value for --version}"
      shift 2
      ;;
    --dist-dir)
      DIST_DIR="${2:?missing value for --dist-dir}"
      shift 2
      ;;
    --arch)
      ARCH="${2:?missing value for --arch}"
      shift 2
      ;;
    --app)
      APP_BUNDLE="${2:?missing value for --app}"
      shift 2
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

if [ -z "$VERSION" ]; then
  echo "missing required --version" >&2
  usage
  exit 2
fi

if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "invalid semantic version: $VERSION" >&2
  exit 2
fi

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    echo "unsupported macOS artifact architecture: $ARCH" >&2
    exit 2
    ;;
esac

APP_BUNDLE="${APP_BUNDLE:-$DIST_DIR/Conjet.app}"
if [ ! -d "$APP_BUNDLE" ]; then
  echo "missing app bundle: $APP_BUNDLE" >&2
  exit 1
fi

ARTIFACT_BASE="conjet-${VERSION}-macos-${ARCH}"
STAGING_ROOT="$DIST_DIR/dmg-staging/$ARTIFACT_BASE"
DMG_PATH="$DIST_DIR/${ARTIFACT_BASE}.dmg"

rm -rf "$STAGING_ROOT" "$DMG_PATH" "$DMG_PATH.sha256"
mkdir -p "$STAGING_ROOT/bin"

/usr/bin/ditto "$APP_BUNDLE" "$STAGING_ROOT/Conjet.app"
/usr/bin/ditto "$APP_BUNDLE/Contents/Resources/ConjetTools/conjet" "$STAGING_ROOT/bin/conjet"
/usr/bin/ditto "$APP_BUNDLE/Contents/Resources/ConjetTools/conjetd" "$STAGING_ROOT/bin/conjetd"
ln -s /Applications "$STAGING_ROOT/Applications"

if [ -f "$ROOT_DIR/README.md" ]; then
  /usr/bin/ditto "$ROOT_DIR/README.md" "$STAGING_ROOT/README.md"
fi

cat >"$STAGING_ROOT/INSTALL.txt" <<INSTALL
Conjet ${VERSION}

Drag Conjet.app to Applications, or install with Homebrew:

  brew tap omega13-engr/conjet https://github.com/omega13-engr/conjet.git
  brew install conjet

The bin directory contains signed conjet and conjetd command-line tools.
INSTALL

/usr/bin/xattr -cr "$STAGING_ROOT"

/usr/bin/codesign --verify --deep --strict "$STAGING_ROOT/Conjet.app"
/usr/bin/codesign --verify --strict "$STAGING_ROOT/bin/conjet"
/usr/bin/codesign --verify --strict "$STAGING_ROOT/bin/conjetd"

/usr/bin/hdiutil create \
  -volname "Conjet ${VERSION}" \
  -srcfolder "$STAGING_ROOT" \
  -format UDZO \
  -fs HFS+ \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG_PATH"

/usr/bin/hdiutil verify "$DMG_PATH"
/usr/bin/shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"

printf '%s\n' "$DMG_PATH"

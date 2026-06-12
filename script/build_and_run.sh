#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Conjet"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ENTITLEMENTS="$ROOT_DIR/build-support/conjet-debug.entitlements"

cd "$ROOT_DIR"

if [ "$MODE" != "--stage" ] && [ "$MODE" != "stage" ]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

"$ROOT_DIR/build-support/stage-macos-app.sh" \
  --configuration debug \
  --dist-dir "$DIST_DIR" \
  --signing-identity "${CONJET_CODE_SIGN_IDENTITY:--}" \
  --entitlements "$ENTITLEMENTS"

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
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"dev.conjet.app\""
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

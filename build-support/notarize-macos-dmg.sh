#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: notarize-macos-dmg.sh PATH_TO_DMG

Requires either:
  NOTARYTOOL_KEYCHAIN_PROFILE

or all of:
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_SPECIFIC_PASSWORD
USAGE
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

DMG_PATH="$1"
if [ ! -f "$DMG_PATH" ]; then
  echo "missing dmg: $DMG_PATH" >&2
  exit 1
fi

submit_args=("$DMG_PATH" --wait)
if [ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]; then
  submit_args+=(--keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE")
else
  : "${APPLE_ID:?APPLE_ID is required when NOTARYTOOL_KEYCHAIN_PROFILE is not set}"
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required when NOTARYTOOL_KEYCHAIN_PROFILE is not set}"
  : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required when NOTARYTOOL_KEYCHAIN_PROFILE is not set}"
  submit_args+=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
fi

/usr/bin/xcrun notarytool submit "${submit_args[@]}"
/usr/bin/xcrun stapler staple "$DMG_PATH"
/usr/bin/xcrun stapler validate "$DMG_PATH"
/usr/sbin/spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"

#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$DIST_DIR/OrbitDock.xcarchive}"
APP_NAME="${APP_NAME:-OrbitDock}"
VERSION="${VERSION:?VERSION is required}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/Robdel12/OrbitDock/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:?SPARKLE_PUBLIC_ED_KEY is required}"
MACOS_DEVELOPMENT_TEAM="${MACOS_DEVELOPMENT_TEAM:?MACOS_DEVELOPMENT_TEAM is required}"

if [[ "${SKIP_NOTARIZATION:-0}" != "1" ]]; then
  : "${APPLE_NOTARY_KEY_ID:?APPLE_NOTARY_KEY_ID is required}"
  : "${APPLE_NOTARY_ISSUER_ID:?APPLE_NOTARY_ISSUER_ID is required}"
  : "${APPLE_NOTARY_PRIVATE_KEY:?APPLE_NOTARY_PRIVATE_KEY is required}"
fi

mkdir -p "$DIST_DIR"
rm -rf "$ARCHIVE_PATH"

pushd "$ROOT_DIR" >/dev/null

make rust-build-darwin

XCODEBUILD_ARGS=(
  archive
  -project OrbitDockNative/OrbitDock.xcodeproj
  -scheme OrbitDock
  -configuration Release
  -destination 'generic/platform=macOS'
  -archivePath "$ARCHIVE_PATH"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="Developer ID Application"
  DEVELOPMENT_TEAM="$MACOS_DEVELOPMENT_TEAM"
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL"
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY"
)

if [[ -n "${OTHER_CODE_SIGN_FLAGS:-}" ]]; then
  XCODEBUILD_ARGS+=("OTHER_CODE_SIGN_FLAGS=${OTHER_CODE_SIGN_FLAGS}")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}"

APP_PATH="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: missing archived app at $APP_PATH"
  exit 1
fi

SUBMISSION_ZIP="$DIST_DIR/${APP_NAME}-${VERSION}-notarization.zip"
FINAL_ZIP="$DIST_DIR/${APP_NAME}-${VERSION}.zip"
rm -f "$SUBMISSION_ZIP" "$FINAL_ZIP" "$FINAL_ZIP.sha256"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$SUBMISSION_ZIP"

if [[ "${SKIP_NOTARIZATION:-0}" != "1" ]]; then
  NOTARY_KEY_PATH="$DIST_DIR/notary-api-key.p8"
  printf '%s' "$APPLE_NOTARY_PRIVATE_KEY" > "$NOTARY_KEY_PATH"

  xcrun notarytool submit "$SUBMISSION_ZIP" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait

  xcrun stapler staple "$APP_PATH"
  spctl -a -vvv --type exec "$APP_PATH"

  rm -f "$NOTARY_KEY_PATH"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$FINAL_ZIP"
shasum -a 256 "$FINAL_ZIP" > "$FINAL_ZIP.sha256"

rm -f "$SUBMISSION_ZIP"

popd >/dev/null

echo "Created $FINAL_ZIP"

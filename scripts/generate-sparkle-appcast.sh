#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SITE_DIR="${SITE_DIR:?SITE_DIR is required}"
RELEASE_TAG="${RELEASE_TAG:?RELEASE_TAG is required}"
SPARKLE_PRIVATE_ED_KEY="${SPARKLE_PRIVATE_ED_KEY:?SPARKLE_PRIVATE_ED_KEY is required}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/Robdel12/OrbitDock/releases/download/${RELEASE_TAG}/}"
APPCAST_FILENAME="${APPCAST_FILENAME:-appcast.xml}"

VERSION="${RELEASE_TAG#v}"
APP_NAME="${APP_NAME:-OrbitDock}"
ARCHIVE_NAME="${APP_NAME}-${VERSION}.zip"
ARCHIVE_PATH="$SITE_DIR/$ARCHIVE_NAME"
RELEASE_NOTES_PATH="$SITE_DIR/${APP_NAME}-${VERSION}.md"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "error: missing archive $ARCHIVE_PATH"
  exit 1
fi

SPARKLE_BIN_DIR="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*SourcePackages/artifacts/sparkle/Sparkle/bin' | head -n 1)"
if [[ -z "$SPARKLE_BIN_DIR" ]]; then
  echo "error: Sparkle tools not found in Xcode DerivedData"
  exit 1
fi

mkdir -p "$SITE_DIR"
touch "$SITE_DIR/.nojekyll"

if [[ ! -f "$RELEASE_NOTES_PATH" ]]; then
  {
    printf '# %s %s\n\n' "$APP_NAME" "$VERSION"
    printf 'See the GitHub release for details.\n'
  } > "$RELEASE_NOTES_PATH"
fi

printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$SPARKLE_BIN_DIR/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --embed-release-notes \
  -o "$APPCAST_FILENAME" \
  "$SITE_DIR"

echo "Generated $SITE_DIR/$APPCAST_FILENAME"

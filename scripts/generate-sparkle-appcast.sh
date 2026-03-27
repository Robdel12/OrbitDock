#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SITE_DIR="${SITE_DIR:-$ROOT_DIR/dist}"
RELEASE_TAG="${RELEASE_TAG:-$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "")}"
if [[ -z "$RELEASE_TAG" ]]; then
  echo "error: no git tag found — set RELEASE_TAG or create a tag first"
  exit 1
fi
RELEASE_VERSION="${RELEASE_VERSION:-${RELEASE_TAG#v}}"
SPARKLE_PRIVATE_ED_KEY="${SPARKLE_PRIVATE_ED_KEY:?SPARKLE_PRIVATE_ED_KEY is required}"
XCODE_DERIVED_DATA_PATH="${XCODE_DERIVED_DATA_PATH:-$ROOT_DIR/.build/release-deriveddata}"

# Channel support: stable (default), beta, nightly.
# Sets APPCAST_FILENAME automatically when CHANNEL is provided.
CHANNEL="${CHANNEL:-stable}"
case "$CHANNEL" in
  stable)  APPCAST_FILENAME="${APPCAST_FILENAME:-appcast.xml}" ;;
  beta)    APPCAST_FILENAME="${APPCAST_FILENAME:-appcast-beta.xml}" ;;
  nightly) APPCAST_FILENAME="${APPCAST_FILENAME:-appcast-nightly.xml}" ;;
  *)
    echo "error: unknown channel '$CHANNEL' (expected stable, beta, or nightly)"
    exit 1
    ;;
esac

DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/Robdel12/OrbitDock/releases/download/${RELEASE_TAG}/}"

VERSION="$RELEASE_VERSION"
APP_NAME="${APP_NAME:-OrbitDock}"
ARCHIVE_NAME="${APP_NAME}-${VERSION}.zip"
ARCHIVE_PATH="$SITE_DIR/$ARCHIVE_NAME"
RELEASE_NOTES_PATH="$SITE_DIR/${APP_NAME}-${VERSION}.md"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "error: missing archive $ARCHIVE_PATH"
  exit 1
fi

SPARKLE_BIN_DIR=""
for search_root in "$XCODE_DERIVED_DATA_PATH" "$HOME/Library/Developer/Xcode/DerivedData"; do
  [[ -d "$search_root" ]] || continue
  SPARKLE_BIN_DIR="$(find "$search_root" -path '*SourcePackages/artifacts/sparkle/Sparkle/bin' 2>/dev/null | head -n 1 || true)"
  [[ -n "$SPARKLE_BIN_DIR" ]] && break
done
if [[ -z "$SPARKLE_BIN_DIR" ]]; then
  echo "error: Sparkle tools not found — build the project in Xcode first so SPM resolves Sparkle"
  exit 1
fi

mkdir -p "$SITE_DIR"

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

cp "$ARCHIVE_PATH" "$STAGING_DIR/"

RELEASE_NOTES_PATH="$STAGING_DIR/${APP_NAME}-${VERSION}.md"
if [[ ! -f "$SITE_DIR/${APP_NAME}-${VERSION}.md" ]]; then
  {
    printf '# %s %s\n\n' "$APP_NAME" "$VERSION"
    printf 'See the GitHub release for details.\n'
  } > "$RELEASE_NOTES_PATH"
else
  cp "$SITE_DIR/${APP_NAME}-${VERSION}.md" "$RELEASE_NOTES_PATH"
fi

printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$SPARKLE_BIN_DIR/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --embed-release-notes \
  -o "$SITE_DIR/$APPCAST_FILENAME" \
  "$STAGING_DIR"

echo "Generated $SITE_DIR/$APPCAST_FILENAME (channel=$CHANNEL)"

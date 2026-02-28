#!/bin/bash

# Bundle orbitdock-server in app Resources.
# - Dev/local builds: best-effort copy if a binary already exists.
# - Archive builds (ACTION=install): build a fresh universal binary and verify
#   it was built from the current commit to avoid bundling stale artifacts.

set -euo pipefail

if [[ "${PLATFORM_NAME:-}" != "macosx" ]]; then
  echo "Done!"
  exit 0
fi

REPO_ROOT="${SRCROOT}/.."
RUST_UNIVERSAL_BINARY="${REPO_ROOT}/.cache/rust/target/universal/orbitdock-server"
RUST_UNIVERSAL_GITSHA="${RUST_UNIVERSAL_BINARY}.gitsha"
LEGACY_UNIVERSAL_BINARY="${REPO_ROOT}/orbitdock-server/target/universal/orbitdock-server"
LEGACY_RELEASE_BINARY="${REPO_ROOT}/orbitdock-server/target/release/orbitdock-server"

resolve_server_binary() {
  if [[ -f "$RUST_UNIVERSAL_BINARY" ]]; then
    echo "$RUST_UNIVERSAL_BINARY"
    return
  fi
  if [[ -f "$LEGACY_UNIVERSAL_BINARY" ]]; then
    echo "$LEGACY_UNIVERSAL_BINARY"
    return
  fi
  if [[ -f "$LEGACY_RELEASE_BINARY" ]]; then
    echo "$LEGACY_RELEASE_BINARY"
    return
  fi
  echo ""
}

if [[ "${ACTION:-}" == "install" ]]; then
  echo "Building fresh orbitdock-server universal binary for archive..."
  make -C "$REPO_ROOT" rust-build-universal

  if [[ ! -f "$RUST_UNIVERSAL_BINARY" ]]; then
    echo "error: missing built server binary at ${RUST_UNIVERSAL_BINARY}"
    exit 1
  fi

  if [[ ! -f "$RUST_UNIVERSAL_GITSHA" ]]; then
    echo "error: missing build stamp at ${RUST_UNIVERSAL_GITSHA}"
    exit 1
  fi

  BUILT_SHA="$(tr -d '[:space:]' < "$RUST_UNIVERSAL_GITSHA")"
  if ! CURRENT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"; then
    echo "error: could not resolve workspace HEAD commit for archive validation"
    exit 1
  fi
  CURRENT_SHA="$(echo "$CURRENT_SHA" | tr -d '[:space:]')"

  if [[ -z "$BUILT_SHA" || "$BUILT_SHA" != "$CURRENT_SHA" ]]; then
    echo "error: built server commit (${BUILT_SHA}) does not match workspace HEAD (${CURRENT_SHA})"
    exit 1
  fi

  SERVER_BINARY="$RUST_UNIVERSAL_BINARY"
else
  SERVER_BINARY="$(resolve_server_binary)"
  if [[ -z "$SERVER_BINARY" ]]; then
    echo "note: orbitdock-server binary not found — skipping bundle (dev mode)"
    echo "Done!"
    exit 0
  fi
fi

RESOURCES_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources"
mkdir -p "$RESOURCES_DIR"
cp "$SERVER_BINARY" "$RESOURCES_DIR/orbitdock-server"
chmod +x "$RESOURCES_DIR/orbitdock-server"

echo "Bundled orbitdock-server in Resources (${SERVER_BINARY})"
echo "Done!"

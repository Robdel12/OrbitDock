#!/bin/bash

# Bundle orbitdock in app Resources.
# - Dev/local builds: best-effort copy if a binary already exists.
# - Archive builds (ACTION=install): validate an existing prebuilt macOS binary
#   and ensure it matches the current server sources.

set -euo pipefail

if [[ "${PLATFORM_NAME:-}" != "macosx" ]]; then
  echo "Done!"
  exit 0
fi

REPO_ROOT="${SRCROOT}/.."
RUST_DARWIN_BINARY="${REPO_ROOT}/.cache/rust/target/darwin-arm64/orbitdock"
RUST_UNIVERSAL_BINARY="${REPO_ROOT}/.cache/rust/target/universal/orbitdock"
RUST_DARWIN_GITSHA="${RUST_DARWIN_BINARY}.gitsha"
LEGACY_UNIVERSAL_BINARY="${REPO_ROOT}/orbitdock-server/target/universal/orbitdock"
LEGACY_RELEASE_BINARY="${REPO_ROOT}/orbitdock-server/target/release/orbitdock"
SERVER_FINGERPRINT_SCRIPT="${SRCROOT}/Scripts/server-source-fingerprint.sh"

resolve_server_binary() {
  if [[ -f "$RUST_DARWIN_BINARY" ]]; then
    echo "$RUST_DARWIN_BINARY"
    return
  fi
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

resolve_archive_binary() {
  if [[ -f "$RUST_DARWIN_BINARY" ]]; then
    echo "$RUST_DARWIN_BINARY"
    return
  fi
  if [[ -f "$RUST_UNIVERSAL_BINARY" ]]; then
    echo "$RUST_UNIVERSAL_BINARY"
    return
  fi
  if [[ -f "$LEGACY_UNIVERSAL_BINARY" ]]; then
    echo "$LEGACY_UNIVERSAL_BINARY"
    return
  fi
  echo ""
}

validate_archive_binary() {
  local archive_binary archive_gitsha built_sha current_sha archs

  archive_binary="$(resolve_archive_binary)"
  if [[ -z "$archive_binary" ]]; then
    echo "error: missing prebuilt macOS orbitdock binary"
    echo "Run: make rust-build-darwin"
    exit 1
  fi

  if [[ "$archive_binary" == "$RUST_DARWIN_BINARY" && -f "$RUST_DARWIN_GITSHA" ]]; then
    archive_gitsha="$RUST_DARWIN_GITSHA"
  else
    archive_gitsha="${archive_binary}.gitsha"
  fi

  if [[ ! -f "$archive_gitsha" ]]; then
    echo "error: missing build stamp at ${archive_gitsha}"
    echo "Run: make rust-build-darwin"
    exit 1
  fi

  if ! archs="$(lipo -archs "$archive_binary" 2>/dev/null)"; then
    echo "error: failed to inspect binary architectures: ${archive_binary}"
    exit 1
  fi

  if [[ "$archs" != *"arm64"* ]]; then
    echo "error: binary is not built for macOS arm64: ${archive_binary}"
    echo "Found architectures: ${archs}"
    echo "Run: make rust-build-darwin"
    exit 1
  fi

  built_sha="$(tr -d '[:space:]' < "$archive_gitsha")"
  if [[ "$built_sha" =~ ^[0-9a-f]{40}$ ]] && git -C "$REPO_ROOT" cat-file -e "${built_sha}^{commit}" >/dev/null 2>&1; then
    if ! built_sha="$("$SERVER_FINGERPRINT_SCRIPT" "$built_sha" 2>/dev/null)"; then
      echo "error: could not resolve legacy prebuilt server commit stamp (${built_sha})"
      echo "Run: make rust-build-darwin"
      exit 1
    fi
    built_sha="$(echo "$built_sha" | tr -d '[:space:]')"
  fi

  if ! current_sha="$("$SERVER_FINGERPRINT_SCRIPT" 2>/dev/null)"; then
    echo "error: could not resolve current server source fingerprint for archive validation"
    exit 1
  fi
  current_sha="$(echo "$current_sha" | tr -d '[:space:]')"

  if [[ -z "$built_sha" || "$built_sha" != "$current_sha" ]]; then
    echo "error: prebuilt server fingerprint (${built_sha}) does not match current server sources (${current_sha})"
    echo "Run: make rust-build-darwin"
    exit 1
  fi

  SERVER_BINARY="$archive_binary"
}

sign_bundled_server_binary() {
  local bundled_binary="$1"
  local identity
  local signature_details flags_hex flags_dec has_runtime=0

  if [[ "${CODE_SIGNING_ALLOWED:-NO}" != "YES" ]]; then
    echo "note: CODE_SIGNING_ALLOWED is not YES — skipping explicit server codesign"
    return
  fi

  identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  if [[ -z "$identity" || "$identity" == "-" ]]; then
    if [[ "${ACTION:-}" == "install" ]]; then
      echo "error: missing code signing identity for archive hardened runtime signing"
      exit 1
    fi
    echo "note: no concrete code signing identity — skipping explicit server codesign"
    return
  fi

  /usr/bin/codesign --force --sign "$identity" --options runtime "$bundled_binary"
  /usr/bin/codesign --verify --strict --verbose=2 "$bundled_binary"

  signature_details="$("/usr/bin/codesign" -d --verbose=4 "$bundled_binary" 2>&1 || true)"

  if /usr/bin/printf "%s\n" "$signature_details" | /usr/bin/grep -q "Runtime Version="; then
    has_runtime=1
  fi

  if [[ "$has_runtime" != "1" ]] && /usr/bin/printf "%s\n" "$signature_details" | /usr/bin/grep -Eiq "flags=.*runtime"; then
    has_runtime=1
  fi

  if [[ "$has_runtime" != "1" ]]; then
    flags_hex="$("/usr/bin/printf" "%s\n" "$signature_details" | /usr/bin/sed -n 's/.*flags=0x\([0-9A-Fa-f]\+\).*/\1/p' | /usr/bin/head -n 1)"
    if [[ -n "$flags_hex" ]]; then
      flags_dec=$((16#$flags_hex))
      if (( (flags_dec & 0x10000) != 0 )); then
        has_runtime=1
      fi
    fi
  fi

  if [[ "$has_runtime" != "1" ]]; then
    echo "error: hardened runtime flag missing on bundled orbitdock binary"
    echo "$signature_details"
    exit 1
  fi
}

if [[ "${ACTION:-}" == "install" ]]; then
  echo "Validating prebuilt orbitdock macOS binary for archive..."
  validate_archive_binary
else
  SERVER_BINARY="$(resolve_server_binary)"
  if [[ -z "$SERVER_BINARY" ]]; then
    echo "note: orbitdock binary not found — skipping bundle (dev mode)"
    echo "Done!"
    exit 0
  fi
fi

RESOURCES_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources"
mkdir -p "$RESOURCES_DIR"
cp "$SERVER_BINARY" "$RESOURCES_DIR/orbitdock"
chmod +x "$RESOURCES_DIR/orbitdock"
sign_bundled_server_binary "$RESOURCES_DIR/orbitdock"

echo "Bundled orbitdock in Resources (${SERVER_BINARY})"
echo "Done!"

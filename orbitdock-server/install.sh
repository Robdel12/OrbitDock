#!/usr/bin/env bash
set -euo pipefail

REPO_SLUG="${ORBITDOCK_SERVER_REPO:-Robdel12/OrbitDock}"
REPO_URL="${ORBITDOCK_SERVER_REPO_URL:-https://github.com/${REPO_SLUG}.git}"
SOURCE_REF="${ORBITDOCK_SERVER_REF:-main}"
VERSION="${ORBITDOCK_SERVER_VERSION:-latest}"
INSTALL_ROOT="${ORBITDOCK_INSTALL_ROOT:-$HOME/.orbitdock}"
SKIP_HOOKS="${ORBITDOCK_SKIP_HOOKS:-0}"
SKIP_SERVICE="${ORBITDOCK_SKIP_SERVICE:-0}"
FORCE_SOURCE="${ORBITDOCK_FORCE_SOURCE:-0}"

mkdir -p "$INSTALL_ROOT/bin"

normalize_tag() {
  local raw="$1"
  if [[ "$raw" == v* ]]; then
    echo "$raw"
  else
    echo "v$raw"
  fi
}

asset_name_for_platform() {
  local os
  local arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os/$arch" in
    Darwin/*)
      echo "orbitdock-server-darwin-universal.zip"
      ;;
    Linux/x86_64)
      echo "orbitdock-server-linux-x86_64.zip"
      ;;
    *)
      return 1
      ;;
  esac
}

verify_checksum() {
  local tmp_dir="$1"
  local checksum_path="$2"

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$tmp_dir" && sha256sum -c "$(basename "$checksum_path")" >/dev/null)
    return $?
  fi

  if command -v shasum >/dev/null 2>&1; then
    (cd "$tmp_dir" && shasum -a 256 -c "$(basename "$checksum_path")" >/dev/null)
    return $?
  fi

  echo "warning: sha256 tool not available; skipping checksum verification."
  return 0
}

install_from_release_asset() {
  local asset_name
  local tag
  local url
  local tmp_dir
  local zip_path
  local checksum_url
  local checksum_path

  asset_name="$(asset_name_for_platform)" || return 1

  if [[ "$VERSION" == "latest" ]]; then
    url="https://github.com/${REPO_SLUG}/releases/latest/download/${asset_name}"
  else
    tag="$(normalize_tag "$VERSION")"
    url="https://github.com/${REPO_SLUG}/releases/download/${tag}/${asset_name}"
  fi

  if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    return 1
  fi

  tmp_dir="$(mktemp -d)"
  zip_path="$tmp_dir/$asset_name"
  checksum_url="${url}.sha256"
  checksum_path="$tmp_dir/${asset_name}.sha256"

  if ! curl -fsSL "$url" -o "$zip_path"; then
    rm -rf "$tmp_dir"
    return 1
  fi

  if curl -fsSL "$checksum_url" -o "$checksum_path"; then
    if ! verify_checksum "$tmp_dir" "$checksum_path"; then
      echo "error: checksum verification failed for $asset_name"
      rm -rf "$tmp_dir"
      return 1
    fi
  else
    echo "warning: checksum file not found for $asset_name; skipping verification."
  fi

  unzip -q "$zip_path" -d "$tmp_dir"
  if [[ ! -f "$tmp_dir/orbitdock-server" ]]; then
    echo "error: expected orbitdock-server in $asset_name"
    rm -rf "$tmp_dir"
    return 1
  fi

  cp "$tmp_dir/orbitdock-server" "$INSTALL_ROOT/bin/orbitdock-server"
  chmod 755 "$INSTALL_ROOT/bin/orbitdock-server"

  rm -rf "$tmp_dir"
  return 0
}

install_from_source() {
  local args
  args=(install --locked --git "$REPO_URL" --root "$INSTALL_ROOT" --force orbitdock-server)

  if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo is required for source installation but was not found."
    echo "Install Rust first: https://rustup.rs"
    exit 1
  fi

  if [[ "$VERSION" == "latest" ]]; then
    args+=(--branch "$SOURCE_REF")
  else
    args+=(--tag "$(normalize_tag "$VERSION")")
  fi

  cargo "${args[@]}"
}

echo "Installing orbitdock-server to $INSTALL_ROOT/bin..."
if [[ "$FORCE_SOURCE" == "1" ]]; then
  echo "Skipping release assets (ORBITDOCK_FORCE_SOURCE=1)."
  install_from_source
else
  if install_from_release_asset; then
    echo "Installed prebuilt binary from GitHub Releases."
  else
    echo "Prebuilt binary not available for this platform/version. Falling back to source build."
    install_from_source
  fi
fi

SERVER_BIN="$INSTALL_ROOT/bin/orbitdock-server"
if [[ ! -x "$SERVER_BIN" ]]; then
  echo "error: install completed but binary was not found at $SERVER_BIN"
  exit 1
fi

echo "Running setup..."
"$SERVER_BIN" init

if [[ "$SKIP_HOOKS" == "1" ]]; then
  echo "Skipping Claude hook installation (ORBITDOCK_SKIP_HOOKS=1)."
else
  "$SERVER_BIN" install-hooks
fi

if [[ "$SKIP_SERVICE" == "1" ]]; then
  echo "Skipping service installation (ORBITDOCK_SKIP_SERVICE=1)."
else
  "$SERVER_BIN" install-service --enable
fi

echo
echo "Server installed at $SERVER_BIN"
echo "Health endpoint: http://127.0.0.1:4000/health"

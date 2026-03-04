#!/usr/bin/env bash
set -euo pipefail

# ── Color helpers ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD="\033[1m"
  CYAN="\033[36m"
  GREEN="\033[32m"
  RED="\033[31m"
  YELLOW="\033[33m"
  RESET="\033[0m"
else
  BOLD="" CYAN="" GREEN="" RED="" YELLOW="" RESET=""
fi

info()  { echo -e "${CYAN}→${RESET} $*"; }
ok()    { echo -e "${GREEN}✓${RESET} $*"; }
warn()  { echo -e "${YELLOW}!${RESET} $*"; }
err()   { echo -e "${RED}✗${RESET} $*" >&2; }

# ── Configuration ─────────────────────────────────────────────────────────
REPO_SLUG="${ORBITDOCK_SERVER_REPO:-Robdel12/OrbitDock}"
REPO_URL="${ORBITDOCK_SERVER_REPO_URL:-https://github.com/${REPO_SLUG}.git}"
SOURCE_REF="${ORBITDOCK_SERVER_REF:-main}"
VERSION="${ORBITDOCK_SERVER_VERSION:-latest}"
INSTALL_ROOT="${ORBITDOCK_INSTALL_ROOT:-$HOME/.orbitdock}"
SKIP_HOOKS="${ORBITDOCK_SKIP_HOOKS:-0}"
SKIP_SERVICE="${ORBITDOCK_SKIP_SERVICE:-0}"
FORCE_SOURCE="${ORBITDOCK_FORCE_SOURCE:-0}"
SERVER_URL=""

# ── Parse flags ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-url)
      SERVER_URL="$2"
      shift 2
      ;;
    --server-url=*)
      SERVER_URL="${1#*=}"
      shift
      ;;
    --skip-hooks)
      SKIP_HOOKS=1
      shift
      ;;
    --skip-service)
      SKIP_SERVICE=1
      shift
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --version=*)
      VERSION="${1#*=}"
      shift
      ;;
    --force-source)
      FORCE_SOURCE=1
      shift
      ;;
    -h|--help)
      echo "Usage: install.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --server-url <url>   Remote server URL (hooks-only mode — skips service install)"
      echo "  --skip-hooks         Skip Claude hook installation"
      echo "  --skip-service       Skip system service installation"
      echo "  --version <ver>      Install specific version tag (default: latest)"
      echo "  --force-source       Build from source instead of downloading a prebuilt binary"
      echo "  -h, --help           Show this help"
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      exit 1
      ;;
  esac
done

# When --server-url is provided, run in hooks-only mode (skip service install)
if [[ -n "$SERVER_URL" ]]; then
  SKIP_SERVICE=1
fi

mkdir -p "$INSTALL_ROOT/bin"

# ── Helpers ───────────────────────────────────────────────────────────────
normalize_tag() {
  local raw="$1"
  if [[ "$raw" == v* ]]; then
    echo "$raw"
  else
    echo "v$raw"
  fi
}

asset_names_for_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os/$arch" in
    Darwin/*)
      echo "orbitdock-darwin-arm64.zip"
      echo "orbitdock-darwin-universal.zip"
      ;;
    Linux/x86_64)      echo "orbitdock-linux-x86_64.zip" ;;
    Linux/aarch64|Linux/arm64) echo "orbitdock-linux-aarch64.zip" ;;
    *)                 return 1 ;;
  esac
}

verify_checksum() {
  local tmp_dir="$1"
  local checksum_file="$2"

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$tmp_dir" && sha256sum -c "$checksum_file" >/dev/null 2>&1)
    return $?
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$tmp_dir" && shasum -a 256 -c "$checksum_file" >/dev/null 2>&1)
    return $?
  fi

  warn "No sha256 tool found; skipping checksum verification."
  return 0
}

# ── Install from prebuilt binary ──────────────────────────────────────────
install_from_release() {
  local asset_name url tmp_dir zip_path checksum_url checksum_file
  local -a asset_names
  local downloaded=0

  mapfile -t asset_names < <(asset_names_for_platform) || return 1

  if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    warn "curl or unzip not found; can't download prebuilt binary."
    return 1
  fi

  tmp_dir="$(mktemp -d)"

  for asset_name in "${asset_names[@]}"; do
    if [[ "$VERSION" == "latest" ]]; then
      url="https://github.com/${REPO_SLUG}/releases/latest/download/${asset_name}"
    else
      local tag
      tag="$(normalize_tag "$VERSION")"
      url="https://github.com/${REPO_SLUG}/releases/download/${tag}/${asset_name}"
    fi

    zip_path="$tmp_dir/$asset_name"
    checksum_url="${url}.sha256"
    checksum_file="${asset_name}.sha256"

    info "Downloading $asset_name..."
    if curl -fsSL "$url" -o "$zip_path"; then
      downloaded=1
      break
    fi
  done

  if [[ "$downloaded" != "1" ]]; then
    rm -rf "$tmp_dir"
    return 1
  fi

  # Verify checksum if available
  if curl -fsSL "$checksum_url" -o "$tmp_dir/$checksum_file" 2>/dev/null; then
    if ! verify_checksum "$tmp_dir" "$checksum_file"; then
      err "Checksum verification failed!"
      rm -rf "$tmp_dir"
      return 1
    fi
    ok "Checksum verified."
  fi

  unzip -qo "$zip_path" -d "$tmp_dir"
  if [[ ! -f "$tmp_dir/orbitdock" ]]; then
    err "Binary not found in archive."
    rm -rf "$tmp_dir"
    return 1
  fi

  cp "$tmp_dir/orbitdock" "$INSTALL_ROOT/bin/orbitdock"
  chmod 755 "$INSTALL_ROOT/bin/orbitdock"
  rm -rf "$tmp_dir"
  return 0
}

# ── Install from source ──────────────────────────────────────────────────
check_source_prerequisites() {
  local missing=0

  if ! command -v cargo >/dev/null 2>&1; then
    err "cargo not found"
    echo ""
    echo "  The Rust toolchain is required to build from source."
    echo "  Install it with:"
    echo ""
    echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    echo ""
    echo "  Then restart your shell and re-run this installer."
    missing=1
  fi

  if ! command -v git >/dev/null 2>&1; then
    err "git not found"
    echo ""
    echo "  git is required for cargo to fetch the source code."
    echo ""
    echo "    macOS:  xcode-select --install"
    echo "    Ubuntu: sudo apt install git"
    echo "    Fedora: sudo dnf install git"
    missing=1
  fi

  if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    err "C compiler not found"
    echo ""
    echo "  A C compiler is needed for native dependencies (SQLite, etc.)."
    echo ""
    echo "    macOS:  xcode-select --install"
    echo "    Ubuntu: sudo apt install build-essential"
    echo "    Fedora: sudo dnf install gcc"
    missing=1
  fi

  if [[ "$missing" -eq 1 ]]; then
    echo ""
    err "Missing prerequisites. Install them and try again."
    exit 1
  fi
}

install_from_source() {
  check_source_prerequisites

  local args
  args=(install --locked --git "$REPO_URL" --root "$INSTALL_ROOT" --force orbitdock)

  if [[ "$VERSION" == "latest" ]]; then
    args+=(--branch "$SOURCE_REF")
  else
    args+=(--tag "$(normalize_tag "$VERSION")")
  fi

  info "Building from source (this may take a few minutes)..."
  echo ""
  cargo "${args[@]}"
}

# ── Main install flow ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}OrbitDock Server Installer${RESET}"
echo ""

if [[ "$FORCE_SOURCE" == "1" ]]; then
  info "Building from source (--force-source)..."
  install_from_source
elif install_from_release; then
  ok "Installed prebuilt binary."
else
  warn "Prebuilt binary not available for this platform. Falling back to source build..."
  echo ""
  install_from_source
fi

SERVER_BIN="$INSTALL_ROOT/bin/orbitdock"
if [[ ! -x "$SERVER_BIN" ]]; then
  err "Install completed but binary not found at $SERVER_BIN"
  exit 1
fi

ok "Installed to $SERVER_BIN"
echo ""

# ── PATH setup ────────────────────────────────────────────────────────
BIN_DIR="$INSTALL_ROOT/bin"
NEEDS_PATH_RELOAD=0
USED_LEGACY_PATH_SETUP=0

ensure_in_path_legacy() {
  # Already on PATH — nothing to do
  if echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    return
  fi

  local shell_name profile_file line
  shell_name="$(basename "${SHELL:-/bin/bash}")"
  line="export PATH=\"$BIN_DIR:\$PATH\""

  case "$shell_name" in
    zsh)  profile_file="$HOME/.zshrc" ;;
    bash)
      # Prefer .bashrc on Linux, .bash_profile on macOS
      if [[ -f "$HOME/.bash_profile" ]]; then
        profile_file="$HOME/.bash_profile"
      else
        profile_file="$HOME/.bashrc"
      fi
      ;;
    fish)
      profile_file="$HOME/.config/fish/config.fish"
      line="fish_add_path $BIN_DIR"
      ;;
    *)    profile_file="$HOME/.profile" ;;
  esac

  # Don't duplicate if already in the file
  if [[ -f "$profile_file" ]] && grep -qF "$BIN_DIR" "$profile_file" 2>/dev/null; then
    return
  fi

  mkdir -p "$(dirname "$profile_file")"
  echo "" >> "$profile_file"
  echo "# Added by OrbitDock installer" >> "$profile_file"
  echo "$line" >> "$profile_file"

  ok "Added $BIN_DIR to PATH in $profile_file"
  NEEDS_PATH_RELOAD=1
}

if "$SERVER_BIN" --help 2>/dev/null | grep -q "ensure-path"; then
  if ! "$SERVER_BIN" ensure-path; then
    warn "orbitdock-server ensure-path failed; falling back to legacy PATH setup."
    ensure_in_path_legacy
    USED_LEGACY_PATH_SETUP=1
  fi
else
  warn "Installed server doesn't support ensure-path yet; using legacy PATH setup."
  ensure_in_path_legacy
  USED_LEGACY_PATH_SETUP=1
fi

# ── Setup ─────────────────────────────────────────────────────────────────
info "Running initial setup..."

if [[ -n "$SERVER_URL" ]]; then
  "$SERVER_BIN" init --server-url "$SERVER_URL"
else
  "$SERVER_BIN" init
fi

if [[ "$SKIP_HOOKS" == "1" ]]; then
  warn "Skipping Claude hook installation (--skip-hooks)."
else
  if [[ -n "$SERVER_URL" ]]; then
    "$SERVER_BIN" install-hooks --server-url "$SERVER_URL"
  else
    "$SERVER_BIN" install-hooks
  fi
fi

if [[ "$SKIP_SERVICE" == "1" ]]; then
  if [[ -n "$SERVER_URL" ]]; then
    info "Skipping service install (hooks-only mode for remote server)."
  else
    warn "Skipping service installation (--skip-service)."
  fi
else
  "$SERVER_BIN" install-service --enable
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Installation complete!${RESET}"
echo ""
ok "Binary: $SERVER_BIN"

if [[ -n "$SERVER_URL" ]]; then
  ok "Hooks pointing to: $SERVER_URL"
  echo ""
  echo "  Your local Claude Code sessions will report to the remote server."
  echo "  No local server is running — events are forwarded to $SERVER_URL."
else
  ok "Health endpoint: http://127.0.0.1:4000/health"
  echo ""
  echo "  Verify with: orbitdock status"
fi

if [[ "$USED_LEGACY_PATH_SETUP" == "1" && "$NEEDS_PATH_RELOAD" == "1" ]]; then
  echo ""
  warn "Restart your terminal, or run:"
  echo ""
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi
echo ""

#!/usr/bin/env bash
set -euo pipefail

# Normalize empty wrapper vars while preserving intentional wrapper settings.
if [[ -z "${RUSTC_WRAPPER:-}" ]]; then
  unset RUSTC_WRAPPER
fi
if [[ -z "${CARGO_BUILD_RUSTC_WRAPPER:-}" ]]; then
  unset CARGO_BUILD_RUSTC_WRAPPER
fi
export SCCACHE_CACHE_SIZE="${SCCACHE_CACHE_SIZE:-20G}"
TARGET_DIR="${CARGO_TARGET_DIR:-target}"

usage() {
  echo "Usage: $0 <darwin|linux> [output_dir]"
  echo "  darwin: build universal macOS binary and package orbitdock-server-darwin-universal.zip"
  echo "  linux:  build linux x86_64 binary and package orbitdock-server-linux-x86_64.zip"
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

TARGET="$1"
OUTPUT_DIR="${2:-../dist}"

if [[ ! -f "Cargo.toml" ]]; then
  echo "error: run this script from orbitdock-server/"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$(basename "$file")" > "$(basename "$file").sha256"
  else
    shasum -a 256 "$(basename "$file")" > "$(basename "$file").sha256"
  fi
}

case "$TARGET" in
  darwin)
    ./build-universal.sh
    cp "$TARGET_DIR/universal/orbitdock-server" "$OUTPUT_DIR/orbitdock-server"
    chmod +x "$OUTPUT_DIR/orbitdock-server"
    (
      cd "$OUTPUT_DIR"
      zip -q orbitdock-server-darwin-universal.zip orbitdock-server
      sha256_file orbitdock-server-darwin-universal.zip
      rm -f orbitdock-server
    )
    echo "Created $OUTPUT_DIR/orbitdock-server-darwin-universal.zip"
    ;;
  linux)
    cargo build -p orbitdock-server --release
    cp "$TARGET_DIR/release/orbitdock-server" "$OUTPUT_DIR/orbitdock-server"
    chmod +x "$OUTPUT_DIR/orbitdock-server"
    (
      cd "$OUTPUT_DIR"
      zip -q orbitdock-server-linux-x86_64.zip orbitdock-server
      sha256_file orbitdock-server-linux-x86_64.zip
      rm -f orbitdock-server
    )
    echo "Created $OUTPUT_DIR/orbitdock-server-linux-x86_64.zip"
    ;;
  *)
    usage
    exit 1
    ;;
esac

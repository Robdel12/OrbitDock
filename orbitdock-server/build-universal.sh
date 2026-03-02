#!/bin/bash
# Build macOS arm64 binary
set -euo pipefail
TARGET_DIR="${CARGO_TARGET_DIR:-target}"
OUTPUT_DIR="${TARGET_DIR}/darwin-arm64"
OUTPUT_BIN="${OUTPUT_DIR}/orbitdock-server"

echo "🦀 Building OrbitDock Server (macOS arm64)..."
rustup target add aarch64-apple-darwin 2>/dev/null || true
cargo build -p orbitdock-server --release --target aarch64-apple-darwin

mkdir -p "$OUTPUT_DIR"
cp "$TARGET_DIR/aarch64-apple-darwin/release/orbitdock-server" "$OUTPUT_BIN"
chmod +x "$OUTPUT_BIN"

echo ""
echo "✅ macOS arm64 binary created:"
file "$OUTPUT_BIN"
ls -lh "$OUTPUT_BIN"

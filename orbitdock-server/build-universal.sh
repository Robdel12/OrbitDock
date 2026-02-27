#!/bin/bash
# Build universal binary for macOS (arm64 + x86_64)
set -e
TARGET_DIR="${CARGO_TARGET_DIR:-target}"

echo "🦀 Building OrbitDock Server..."

# Ensure targets are installed
rustup target add aarch64-apple-darwin 2>/dev/null || true
rustup target add x86_64-apple-darwin 2>/dev/null || true

# Build for both architectures
echo "📦 Building for arm64..."
cargo build -p orbitdock-server --release --target aarch64-apple-darwin

echo "📦 Building for x86_64..."
cargo build -p orbitdock-server --release --target x86_64-apple-darwin

# Create universal binary
echo "🔗 Creating universal binary..."
mkdir -p "$TARGET_DIR/universal"
lipo -create \
    "$TARGET_DIR/aarch64-apple-darwin/release/orbitdock-server" \
    "$TARGET_DIR/x86_64-apple-darwin/release/orbitdock-server" \
    -output "$TARGET_DIR/universal/orbitdock-server"

# Show result
echo ""
echo "✅ Universal binary created:"
file "$TARGET_DIR/universal/orbitdock-server"
ls -lh "$TARGET_DIR/universal/orbitdock-server"

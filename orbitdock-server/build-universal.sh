#!/bin/bash
# Build universal binary for macOS (arm64 + x86_64)
set -e

echo "🦀 Building OrbitDock Server..."

# Ensure targets are installed
rustup target add aarch64-apple-darwin 2>/dev/null || true
rustup target add x86_64-apple-darwin 2>/dev/null || true

# Build for both architectures
echo "📦 Building for arm64..."
cargo build --release --target aarch64-apple-darwin

echo "📦 Building for x86_64..."
cargo build --release --target x86_64-apple-darwin

# Create universal binary
echo "🔗 Creating universal binary..."
mkdir -p target/universal
lipo -create \
    target/aarch64-apple-darwin/release/orbitdock-server \
    target/x86_64-apple-darwin/release/orbitdock-server \
    -output target/universal/orbitdock-server

# Show result
echo ""
echo "✅ Universal binary created:"
file target/universal/orbitdock-server
ls -lh target/universal/orbitdock-server

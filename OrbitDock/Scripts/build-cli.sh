#!/bin/bash

# Build and embed orbitdock-cli and orbitdock-server in the app bundle
# Runs as an Xcode build phase

set -e

PACKAGE_DIR="${SRCROOT}/OrbitDockCore"
CLI_NAME="orbitdock-cli"
SERVER_DIR="${SRCROOT}/../orbitdock-server"
SERVER_NAME="orbitdock-server"

# Ensure required toolchains are available (Xcode environment may not have them in PATH)
export PATH="/usr/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
if ! command -v swift &> /dev/null; then
    # Try Xcode's swift
    SWIFT_PATH=$(xcrun --find swift 2>/dev/null || echo "")
    if [ -n "$SWIFT_PATH" ]; then
        export PATH="$(dirname "$SWIFT_PATH"):$PATH"
    else
        echo "error: swift not found"
        exit 1
    fi
fi

if ! command -v cargo &> /dev/null; then
    echo "error: cargo not found (expected in \$HOME/.cargo/bin or PATH)"
    exit 1
fi

# Determine build configuration
if [ "$CONFIGURATION" == "Release" ]; then
    BUILD_CONFIG="release"
else
    BUILD_CONFIG="debug"
fi

echo "Building $CLI_NAME ($BUILD_CONFIG)..."
echo "Package dir: $PACKAGE_DIR"

# Build the CLI
cd "$PACKAGE_DIR"
swift build -c $BUILD_CONFIG --product $CLI_NAME 2>&1

BUILT_CLI="$PACKAGE_DIR/.build/$BUILD_CONFIG/$CLI_NAME"
if [ ! -f "$BUILT_CLI" ]; then
    echo "error: CLI binary not found at $BUILT_CLI"
    exit 1
fi

# Copy to app bundle
DEST_DIR="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/MacOS"
mkdir -p "$DEST_DIR"
cp "$BUILT_CLI" "$DEST_DIR/"

echo "Installed $CLI_NAME to $DEST_DIR"

echo "Building $SERVER_NAME ($BUILD_CONFIG)..."
echo "Server dir: $SERVER_DIR"

if [ ! -d "$SERVER_DIR" ]; then
    echo "error: server directory not found at $SERVER_DIR"
    exit 1
fi

if [ "$BUILD_CONFIG" == "release" ]; then
    BUILT_SERVER="$SERVER_DIR/target/release/$SERVER_NAME"
else
    BUILT_SERVER="$SERVER_DIR/target/debug/$SERVER_NAME"
fi

cd "$SERVER_DIR"
if [ "$BUILD_CONFIG" == "release" ]; then
    cargo build -p orbitdock-server --release 2>&1
else
    cargo build -p orbitdock-server 2>&1
fi

if [ ! -f "$BUILT_SERVER" ]; then
    echo "error: Server binary not found at $BUILT_SERVER"
    exit 1
fi

# Copy to app bundle
cp "$BUILT_SERVER" "$DEST_DIR/"

echo "Installed $SERVER_NAME to $DEST_DIR"

# Code sign the CLI with Hardened Runtime (required for notarization)
# Use EXPANDED_CODE_SIGN_IDENTITY which is more reliable during Archive builds
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-$CODE_SIGN_IDENTITY}"

echo "CODE_SIGN_IDENTITY: $CODE_SIGN_IDENTITY"
echo "EXPANDED_CODE_SIGN_IDENTITY: $EXPANDED_CODE_SIGN_IDENTITY"
echo "Using identity: $SIGN_IDENTITY"

if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    echo "Signing $CLI_NAME with Hardened Runtime..."
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DEST_DIR/$CLI_NAME"
    echo "Signing $SERVER_NAME with Hardened Runtime..."
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DEST_DIR/$SERVER_NAME"

    # Verify the signature includes hardened runtime
    echo "Verifying CLI signature..."
    codesign -dv --verbose=4 "$DEST_DIR/$CLI_NAME" 2>&1 | grep -E "(flags|runtime)"
    echo "Verifying server signature..."
    codesign -dv --verbose=4 "$DEST_DIR/$SERVER_NAME" 2>&1 | grep -E "(flags|runtime)"
else
    echo "warning: No code signing identity available, binaries will not be signed"
fi

echo "Done!"

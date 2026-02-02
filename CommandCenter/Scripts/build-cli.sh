#!/bin/bash

# Build and embed orbitdock-cli in the app bundle
# Runs as an Xcode build phase

set -e

PACKAGE_DIR="${SRCROOT}/OrbitDockCore"
CLI_NAME="orbitdock-cli"

# Ensure swift is available (Xcode environment may not have it in PATH)
export PATH="/usr/bin:$PATH"
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

# Find the built binary
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

# Code sign the CLI with Hardened Runtime (required for notarization)
# Use EXPANDED_CODE_SIGN_IDENTITY which is more reliable during Archive builds
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-$CODE_SIGN_IDENTITY}"

echo "CODE_SIGN_IDENTITY: $CODE_SIGN_IDENTITY"
echo "EXPANDED_CODE_SIGN_IDENTITY: $EXPANDED_CODE_SIGN_IDENTITY"
echo "Using identity: $SIGN_IDENTITY"

if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    echo "Signing $CLI_NAME with Hardened Runtime..."
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DEST_DIR/$CLI_NAME"

    # Verify the signature includes hardened runtime
    echo "Verifying signature..."
    codesign -dv --verbose=4 "$DEST_DIR/$CLI_NAME" 2>&1 | grep -E "(flags|runtime)"
else
    echo "warning: No code signing identity available, CLI will not be signed"
fi

echo "Done!"

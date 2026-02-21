#!/bin/bash

# Install hook script to ~/.orbitdock/
# Optionally bundle pre-built server binary in app Resources for user installs.
# The Rust server (orbitdock-server) is built and run separately.

set -e

# Install the hook script to ~/.orbitdock/
HOOK_SRC="${SRCROOT}/../scripts/hook.sh"
HOOK_DEST="$HOME/.orbitdock/hook.sh"
if [ -f "$HOOK_SRC" ]; then
    mkdir -p "$HOME/.orbitdock"
    cp "$HOOK_SRC" "$HOOK_DEST"
    chmod +x "$HOOK_DEST"
    echo "Installed hook.sh to $HOOK_DEST"
fi

# Bundle pre-built server binary if available (for user installs).
# In dev mode (cargo run), the binary typically won't be at the release path,
# so ServerManager falls back to PATH lookup — this is fine.
SERVER_BINARY="${SRCROOT}/../orbitdock-server/target/release/orbitdock-server"
if [ -f "$SERVER_BINARY" ] && [ "${PLATFORM_NAME}" = "macosx" ]; then
    RESOURCES_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources"
    mkdir -p "$RESOURCES_DIR"
    cp "$SERVER_BINARY" "$RESOURCES_DIR/orbitdock-server"
    chmod +x "$RESOURCES_DIR/orbitdock-server"
    echo "Bundled orbitdock-server in Resources"
fi

echo "Done!"

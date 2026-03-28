#!/bin/bash
# Build libghostty-vt for Apple platforms.
#
# Prerequisites: zig 0.15.x on PATH
#
# Usage:
#   ./build.sh            # Build for macOS arm64 only
#   ./build.sh --ios      # Also build for iOS arm64
#
# Output:
#   lib/macos-arm64/libghostty-vt.a
#   lib/ios-arm64/libghostty-vt.a   (if --ios)
#   include/ghostty/                 (C headers)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GHOSTTY_COMMIT="bebca84668947bfc92b9a30ed58712e1c34eee1d"
WORK_DIR="/tmp/ghostty-vt-build"

echo "==> Checking zig..."
zig version

if [ -d "$WORK_DIR" ] && [ -d "$WORK_DIR/.git" ]; then
  echo "==> Using existing checkout at $WORK_DIR"
  cd "$WORK_DIR"
  git fetch --depth 1 origin "$GHOSTTY_COMMIT" 2>/dev/null || true
  git checkout "$GHOSTTY_COMMIT" 2>/dev/null
else
  echo "==> Cloning ghostty at $GHOSTTY_COMMIT..."
  rm -rf "$WORK_DIR"
  git clone --depth 1 https://github.com/ghostty-org/ghostty.git "$WORK_DIR"
  cd "$WORK_DIR"
  git fetch --depth 1 origin "$GHOSTTY_COMMIT"
  git checkout "$GHOSTTY_COMMIT"
fi

echo "==> Building libghostty-vt for macOS arm64..."
zig build -Demit-lib-vt -Doptimize=ReleaseFast

mkdir -p "$SCRIPT_DIR/lib/macos-arm64"
cp zig-out/lib/libghostty-vt.a "$SCRIPT_DIR/lib/macos-arm64/"

# Copy C++ dependency static libs from zig cache.
echo "==> Copying C++ dependency libs (highway, simdutf, utfcpp)..."
find .zig-cache -name "libhighway.a" -exec cp {} "$SCRIPT_DIR/lib/macos-arm64/" \;
find .zig-cache -name "libsimdutf.a" -exec cp {} "$SCRIPT_DIR/lib/macos-arm64/" \;
find .zig-cache -name "libutfcpp.a" -exec cp {} "$SCRIPT_DIR/lib/macos-arm64/" \;

# Copy headers
rm -rf "$SCRIPT_DIR/include/ghostty"
cp -r zig-out/include/ghostty "$SCRIPT_DIR/include/"

if [ "${1:-}" = "--ios" ]; then
  echo "==> Building libghostty-vt for iOS arm64..."
  zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dtarget=aarch64-ios
  mkdir -p "$SCRIPT_DIR/lib/ios-arm64"
  cp zig-out/lib/libghostty-vt.a "$SCRIPT_DIR/lib/ios-arm64/"
fi

echo "==> Done. Output:"
ls -lh "$SCRIPT_DIR/lib/"*/libghostty-vt.a
echo "Headers: $SCRIPT_DIR/include/ghostty/"

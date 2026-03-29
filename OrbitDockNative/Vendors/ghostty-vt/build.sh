#!/bin/bash
# Build libghostty-vt for Apple platforms.
#
# Prerequisites: zig 0.15.x on PATH
#
# Usage:
#   ./build.sh                 # Build for macOS arm64 only
#   ./build.sh --ios           # Also build for iOS arm64 and a universal iOS simulator archive
#
# Output:
#   lib/macos-arm64/libghostty-vt.a
#   lib/ios-arm64/libghostty-vt.a             (if --ios)
#   lib/ios-simulator/libghostty-vt.a         (if --ios, universal arm64 + x86_64)
#   include/ghostty/                 (C headers)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GHOSTTY_COMMIT="bebca84668947bfc92b9a30ed58712e1c34eee1d"
WORK_DIR="/tmp/ghostty-vt-build"
SIM_ARM64_CACHE_DIR="/tmp/ghostty-vt-sim-arm64-cache"
SIM_X86_64_CACHE_DIR="/tmp/ghostty-vt-sim-x86_64-cache"
SIM_GLOBAL_CACHE_DIR="/tmp/ghostty-vt-sim-global-cache"

echo "==> Checking zig..."
zig version

copy_cpp_deps() {
  local search_dir="$1"
  local output_dir="$2"

  echo "==> Copying C++ dependency libs into $output_dir..."
  find "$search_dir" -name "libhighway.a" -exec cp {} "$output_dir/" \;
  find "$search_dir" -name "libsimdutf.a" -exec cp {} "$output_dir/" \;
  find "$search_dir" -name "libutfcpp.a" -exec cp {} "$output_dir/" \;
}

create_universal_archive() {
  local output_path="$1"
  shift
  xcrun lipo -create "$@" -output "$output_path"
}

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
copy_cpp_deps ".zig-cache" "$SCRIPT_DIR/lib/macos-arm64"

# Copy headers
rm -rf "$SCRIPT_DIR/include/ghostty"
cp -r zig-out/include/ghostty "$SCRIPT_DIR/include/"

if [ "${1:-}" = "--ios" ]; then
  echo "==> Building libghostty-vt for iOS arm64..."
  zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dtarget=aarch64-ios
  mkdir -p "$SCRIPT_DIR/lib/ios-arm64"
  cp zig-out/lib/libghostty-vt.a "$SCRIPT_DIR/lib/ios-arm64/"
  copy_cpp_deps ".zig-cache" "$SCRIPT_DIR/lib/ios-arm64"

  echo "==> Building libghostty-vt for iOS simulator arm64..."
  rm -rf "$SIM_ARM64_CACHE_DIR" "$SIM_X86_64_CACHE_DIR" "$SIM_GLOBAL_CACHE_DIR"
  mkdir -p "$SIM_GLOBAL_CACHE_DIR"
  if [ -d "$HOME/.cache/zig/p" ]; then
    cp -R "$HOME/.cache/zig/p" "$SIM_GLOBAL_CACHE_DIR/"
  fi
  zig build \
    -Demit-lib-vt \
    -Doptimize=ReleaseFast \
    -Dtarget=aarch64-ios-simulator \
    -Dcpu=apple_a17 \
    --cache-dir "$SIM_ARM64_CACHE_DIR" \
    --global-cache-dir "$SIM_GLOBAL_CACHE_DIR"
  mkdir -p "$SCRIPT_DIR/lib/ios-simulator-arm64"
  cp zig-out/lib/libghostty-vt.a "$SCRIPT_DIR/lib/ios-simulator-arm64/"
  copy_cpp_deps "$SIM_ARM64_CACHE_DIR" "$SCRIPT_DIR/lib/ios-simulator-arm64"

  echo "==> Building libghostty-vt for iOS simulator x86_64..."
  zig build \
    -Demit-lib-vt \
    -Doptimize=ReleaseFast \
    -Dtarget=x86_64-ios-simulator \
    --cache-dir "$SIM_X86_64_CACHE_DIR" \
    --global-cache-dir "$SIM_GLOBAL_CACHE_DIR"
  mkdir -p "$SCRIPT_DIR/lib/ios-simulator-x86_64"
  cp zig-out/lib/libghostty-vt.a "$SCRIPT_DIR/lib/ios-simulator-x86_64/"
  copy_cpp_deps "$SIM_X86_64_CACHE_DIR" "$SCRIPT_DIR/lib/ios-simulator-x86_64"

  echo "==> Creating universal iOS simulator archives..."
  mkdir -p "$SCRIPT_DIR/lib/ios-simulator"
  create_universal_archive \
    "$SCRIPT_DIR/lib/ios-simulator/libghostty-vt.a" \
    "$SCRIPT_DIR/lib/ios-simulator-arm64/libghostty-vt.a" \
    "$SCRIPT_DIR/lib/ios-simulator-x86_64/libghostty-vt.a"
  create_universal_archive \
    "$SCRIPT_DIR/lib/ios-simulator/libhighway.a" \
    "$SCRIPT_DIR/lib/ios-simulator-arm64/libhighway.a" \
    "$SCRIPT_DIR/lib/ios-simulator-x86_64/libhighway.a"
  create_universal_archive \
    "$SCRIPT_DIR/lib/ios-simulator/libsimdutf.a" \
    "$SCRIPT_DIR/lib/ios-simulator-arm64/libsimdutf.a" \
    "$SCRIPT_DIR/lib/ios-simulator-x86_64/libsimdutf.a"
  create_universal_archive \
    "$SCRIPT_DIR/lib/ios-simulator/libutfcpp.a" \
    "$SCRIPT_DIR/lib/ios-simulator-arm64/libutfcpp.a" \
    "$SCRIPT_DIR/lib/ios-simulator-x86_64/libutfcpp.a"
fi

echo "==> Done. Output:"
ls -lh "$SCRIPT_DIR/lib/"*/libghostty-vt.a
echo "Headers: $SCRIPT_DIR/include/ghostty/"

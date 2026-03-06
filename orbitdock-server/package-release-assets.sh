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
LINUX_BUILD_MODE="${ORBITDOCK_LINUX_BUILD_MODE:-auto}"
LINUX_PROFILE_PRESET="${ORBITDOCK_LINUX_PROFILE_PRESET:-release}"
LINUX_DOCKER_CARGO_BUILD_JOBS="${ORBITDOCK_LINUX_DOCKER_CARGO_BUILD_JOBS:-}"
REPO_ROOT="$(cd .. && pwd)"

usage() {
  echo "Usage: $0 <darwin|linux|linux-x86_64|linux-aarch64> [output_dir]"
  echo "  darwin: build macOS arm64 binary and package orbitdock-darwin-arm64.zip"
  echo "  linux:  build linux binary for current Linux host arch (x86_64 or aarch64)"
  echo "  linux-x86_64: build x86_64-unknown-linux-gnu binary and package orbitdock-linux-x86_64.zip"
  echo "  linux-aarch64: build aarch64-unknown-linux-gnu binary and package orbitdock-linux-aarch64.zip"
  echo ""
  echo "Linux build mode (ORBITDOCK_LINUX_BUILD_MODE):"
  echo "  auto   (default) use native Linux build on matching host arch, otherwise Docker"
  echo "  native force native cargo builds"
  echo "  docker force Docker builds"
  echo ""
  echo "Docker cache mode (ORBITDOCK_LINUX_DOCKER_CACHE_MODE):"
  echo "  local  (default) persist buildx cache under repo .cache/"
  echo "  none   disable explicit local cache import/export"
  echo "  Cache root override: ORBITDOCK_LINUX_DOCKER_CACHE_ROOT"
  echo "  Optional: ORBITDOCK_LINUX_DOCKER_CARGO_BUILD_JOBS=<n> to cap Docker cargo parallelism"
  echo ""
  echo "Linux build profile preset (ORBITDOCK_LINUX_PROFILE_PRESET):"
  echo "  release (default) full release profile from Cargo.toml"
  echo "  release-lowmem lower-memory release profile (sets LTO=thin, codegen-units=8)"
  echo "  smoke   faster local validation (disables release LTO, sets codegen-units=16)"
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

LINUX_CARGO_ENV=()
LINUX_DOCKER_BUILD_ARGS=()
case "$LINUX_PROFILE_PRESET" in
  release)
    ;;
  release-lowmem)
    LINUX_CARGO_ENV+=("CARGO_PROFILE_RELEASE_LTO=thin")
    LINUX_CARGO_ENV+=("CARGO_PROFILE_RELEASE_CODEGEN_UNITS=8")
    LINUX_DOCKER_BUILD_ARGS+=(--build-arg "CARGO_PROFILE_RELEASE_LTO=thin")
    LINUX_DOCKER_BUILD_ARGS+=(--build-arg "CARGO_PROFILE_RELEASE_CODEGEN_UNITS=8")
    ;;
  smoke)
    LINUX_CARGO_ENV+=("CARGO_PROFILE_RELEASE_LTO=false")
    LINUX_CARGO_ENV+=("CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16")
    LINUX_DOCKER_BUILD_ARGS+=(--build-arg "CARGO_PROFILE_RELEASE_LTO=false")
    LINUX_DOCKER_BUILD_ARGS+=(--build-arg "CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16")
    ;;
  *)
    echo "error: invalid ORBITDOCK_LINUX_PROFILE_PRESET='$LINUX_PROFILE_PRESET' (expected release|release-lowmem|smoke)"
    exit 1
    ;;
esac

if [[ -n "$LINUX_DOCKER_CARGO_BUILD_JOBS" && ! "$LINUX_DOCKER_CARGO_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: ORBITDOCK_LINUX_DOCKER_CARGO_BUILD_JOBS must be a positive integer"
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

package_binary() {
  local binary_path="$1"
  local archive_name="$2"

  cp "$binary_path" "$OUTPUT_DIR/orbitdock"
  chmod +x "$OUTPUT_DIR/orbitdock"
  (
    cd "$OUTPUT_DIR"
    zip -q "$archive_name" orbitdock
    sha256_file "$archive_name"
    rm -f orbitdock
  )
  echo "Created $OUTPUT_DIR/$archive_name"
}

refresh_darwin_archive_binary() {
  local binary_path="$1"
  local darwin_output_dir="$TARGET_DIR/darwin-arm64"

  mkdir -p "$darwin_output_dir"
  cp "$binary_path" "$darwin_output_dir/orbitdock"
  chmod +x "$darwin_output_dir/orbitdock"
  "$REPO_ROOT/OrbitDock/Scripts/server-source-fingerprint.sh" > "$darwin_output_dir/orbitdock.gitsha"
}

build_linux_target() {
  local rust_target="$1"
  local archive_name="$2"

  rustup target add "$rust_target"
  if [[ ${#LINUX_CARGO_ENV[@]} -gt 0 ]]; then
    env "${LINUX_CARGO_ENV[@]}" cargo build -p orbitdock --release --target "$rust_target"
  else
    cargo build -p orbitdock --release --target "$rust_target"
  fi
  package_binary "$TARGET_DIR/$rust_target/release/orbitdock" "$archive_name"
}

docker_platform_for_rust_target() {
  local rust_target="$1"
  case "$rust_target" in
    x86_64-unknown-linux-gnu) echo "linux/amd64" ;;
    aarch64-unknown-linux-gnu) echo "linux/arm64" ;;
    *)
      echo "error: unsupported rust target for Docker platform mapping: $rust_target" >&2
      return 1
      ;;
  esac
}

linux_arch_for_rust_target() {
  local rust_target="$1"
  case "$rust_target" in
    x86_64-unknown-linux-gnu) echo "x86_64" ;;
    aarch64-unknown-linux-gnu) echo "aarch64" ;;
    *)
      echo "error: unsupported rust target for Linux arch mapping: $rust_target" >&2
      return 1
      ;;
  esac
}

normalized_linux_host_arch() {
  case "$(uname -m)" in
    x86_64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) echo "unknown" ;;
  esac
}

build_linux_target_docker() {
  local rust_target="$1"
  local archive_name="$2"
  local docker_platform tmp_dir repo_root
  local cache_mode cache_root cache_key cache_dir cache_next
  local cache_args=()
  local docker_build_args=("${LINUX_DOCKER_BUILD_ARGS[@]}")

  docker_platform="$(docker_platform_for_rust_target "$rust_target")"
  repo_root="$(cd .. && pwd)"
  cache_mode="${ORBITDOCK_LINUX_DOCKER_CACHE_MODE:-local}"
  cache_root="${ORBITDOCK_LINUX_DOCKER_CACHE_ROOT:-$repo_root/.cache/docker-buildx/orbitdock-server}"

  if ! command -v docker >/dev/null 2>&1; then
    echo "error: Docker is required for Linux Docker builds but was not found."
    exit 1
  fi
  if ! docker buildx version >/dev/null 2>&1; then
    echo "error: docker buildx is required for Linux Docker builds."
    exit 1
  fi

  case "$cache_mode" in
    local)
      cache_key="${docker_platform//\//-}-${LINUX_PROFILE_PRESET}"
      cache_dir="$cache_root/$cache_key"
      cache_next="$cache_root/${cache_key}.next"
      mkdir -p "$cache_root"
      rm -rf "$cache_next"
      if [[ -d "$cache_dir" ]]; then
        cache_args+=(--cache-from "type=local,src=$cache_dir")
      fi
      cache_args+=(--cache-to "type=local,dest=$cache_next,mode=max")
      ;;
    none)
      ;;
    *)
      echo "error: invalid ORBITDOCK_LINUX_DOCKER_CACHE_MODE='$cache_mode' (expected local|none)"
      exit 1
      ;;
  esac

  if [[ -n "$LINUX_DOCKER_CARGO_BUILD_JOBS" ]]; then
    docker_build_args+=(--build-arg "CARGO_BUILD_JOBS=$LINUX_DOCKER_CARGO_BUILD_JOBS")
  fi

  tmp_dir="$(mktemp -d)"
  docker buildx build \
    --platform "$docker_platform" \
    --build-arg "RUST_TARGET=$rust_target" \
    "${docker_build_args[@]}" \
    "${cache_args[@]}" \
    --target export \
    --output "type=local,dest=$tmp_dir" \
    -f "$repo_root/orbitdock-server/docker/linux-release.Dockerfile" \
    "$repo_root"

  if [[ "$cache_mode" == "local" ]]; then
    rm -rf "$cache_dir"
    mv "$cache_next" "$cache_dir"
  fi

  package_binary "$tmp_dir/orbitdock" "$archive_name"
  rm -rf "$tmp_dir"
}

build_linux_release() {
  local rust_target="$1"
  local archive_name="$2"
  local target_arch host_arch

  target_arch="$(linux_arch_for_rust_target "$rust_target")"
  host_arch="$(normalized_linux_host_arch)"

  case "$LINUX_BUILD_MODE" in
    native)
      build_linux_target "$rust_target" "$archive_name"
      ;;
    docker)
      build_linux_target_docker "$rust_target" "$archive_name"
      ;;
    auto)
      if [[ "$(uname -s)" == "Linux" && "$host_arch" == "$target_arch" ]]; then
        build_linux_target "$rust_target" "$archive_name"
      else
        build_linux_target_docker "$rust_target" "$archive_name"
      fi
      ;;
    *)
      echo "error: invalid ORBITDOCK_LINUX_BUILD_MODE='$LINUX_BUILD_MODE' (expected auto|native|docker)"
      exit 1
      ;;
  esac
}

if [[ "$TARGET" == "linux" ]]; then
  if [[ "$(uname -s)" == "Linux" ]]; then
    case "$(uname -m)" in
      x86_64)
        TARGET="linux-x86_64"
        ;;
      aarch64|arm64)
        TARGET="linux-aarch64"
        ;;
      *)
        echo "error: unsupported Linux host arch for 'linux' target: $(uname -m)"
        echo "Use one of: linux-x86_64, linux-aarch64"
        exit 1
        ;;
    esac
  else
    TARGET="linux-x86_64"
  fi
fi

case "$TARGET" in
  darwin)
    rustup target add aarch64-apple-darwin
    cargo build -p orbitdock --release --target aarch64-apple-darwin
    refresh_darwin_archive_binary "$TARGET_DIR/aarch64-apple-darwin/release/orbitdock"
    package_binary "$TARGET_DIR/darwin-arm64/orbitdock" "orbitdock-darwin-arm64.zip"
    ;;
  linux-x86_64)
    build_linux_release x86_64-unknown-linux-gnu orbitdock-linux-x86_64.zip
    ;;
  linux-aarch64)
    build_linux_release aarch64-unknown-linux-gnu orbitdock-linux-aarch64.zip
    ;;
  *)
    usage
    exit 1
    ;;
esac

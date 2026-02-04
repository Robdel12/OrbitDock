#!/bin/bash
set -euo pipefail

# OrbitDock UI Test Runner
# Works locally and in CI with xcbeautify formatting

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_PATH="$PROJECT_ROOT/CommandCenter/CommandCenter.xcodeproj"
SCHEME="CommandCenter"
TEST_TARGET="CommandCenterUITests"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log() { echo -e "${CYAN}▸${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

# Check for xcbeautify, install if missing
ensure_xcbeautify() {
  if ! command -v xcbeautify &> /dev/null; then
    warn "xcbeautify not found, installing..."
    if command -v brew &> /dev/null; then
      brew install xcbeautify
    else
      error "Homebrew not found. Install xcbeautify manually: brew install xcbeautify"
      exit 1
    fi
  fi
}

# Parse arguments
VIZZLY_MODE=""
FILTER=""
QUIET=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --vizzly)
      VIZZLY_MODE="$2"
      shift 2
      ;;
    --filter)
      FILTER="$2"
      shift 2
      ;;
    --quiet|-q)
      QUIET=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --vizzly <mode>   Run with Vizzly: 'tdd' (local) or 'ci' (CI mode)"
      echo "  --filter <test>   Run specific test (e.g., 'testDashboard')"
      echo "  --quiet, -q       Suppress xcbeautify output, show summary only"
      echo "  --help, -h        Show this help"
      echo ""
      echo "Examples:"
      echo "  $0                      # Run all UI tests"
      echo "  $0 --vizzly tdd         # Run with Vizzly TDD server"
      echo "  $0 --vizzly ci          # Run in CI mode with Vizzly"
      echo "  $0 --filter Dashboard   # Run only Dashboard tests"
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      exit 1
      ;;
  esac
done

ensure_xcbeautify

log "Building and running UI tests..."

# Use a different bundle ID for tests to avoid conflicts with running dev app
TEST_BUNDLE_ID="com.stubborn-mule-software.OrbitDock-Testing"

# Build xcodebuild command
XCODE_CMD=(
  xcodebuild test
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -destination "platform=macOS"
  -only-testing:"$TEST_TARGET"
  -resultBundlePath "$PROJECT_ROOT/.build/test-results.xcresult"
  "PRODUCT_BUNDLE_IDENTIFIER=$TEST_BUNDLE_ID"
)

# In CI, disable code signing
if [[ -n "${CI:-}" ]]; then
  XCODE_CMD+=(
    "CODE_SIGN_IDENTITY=-"
    "CODE_SIGNING_REQUIRED=NO"
    "CODE_SIGNING_ALLOWED=NO"
  )
fi

# Add test filter if specified
if [[ -n "$FILTER" ]]; then
  XCODE_CMD+=(-only-testing:"$TEST_TARGET/$FILTER")
fi

# Clean previous results
rm -rf "$PROJECT_ROOT/.build/test-results.xcresult"

# Run based on mode
run_tests() {
  if $QUIET; then
    "${XCODE_CMD[@]}" 2>&1 | xcbeautify --quiet
  else
    "${XCODE_CMD[@]}" 2>&1 | xcbeautify
  fi
}

case "$VIZZLY_MODE" in
  tdd)
    log "Starting Vizzly TDD server..."
    cd "$PROJECT_ROOT"
    npx vizzly run "set -o pipefail; ${XCODE_CMD[*]} 2>&1 | xcbeautify"
    ;;
  ci)
    if [[ -z "${VIZZLY_TOKEN:-}" ]]; then
      error "VIZZLY_TOKEN environment variable required for CI mode"
      exit 1
    fi
    log "Running with Vizzly CI..."
    cd "$PROJECT_ROOT"
    npx vizzly run "set -o pipefail; ${XCODE_CMD[*]} 2>&1 | xcbeautify"
    ;;
  "")
    # No Vizzly, just run tests
    run_tests
    ;;
  *)
    error "Unknown Vizzly mode: $VIZZLY_MODE (use 'tdd' or 'ci')"
    exit 1
    ;;
esac

EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
  success "All UI tests passed!"
else
  error "Some tests failed"
fi

exit $EXIT_CODE

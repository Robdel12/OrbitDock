#!/usr/bin/env bash

set -euo pipefail

sample_seconds=5
trace_seconds=10
pid=""
out_dir=""
process_pattern="${ORBITDOCK_PROCESS_PATTERN:-OrbitDock.app/Contents/MacOS/OrbitDock}"

usage() {
  cat <<'USAGE'
Capture OrbitDock memory profiling artifacts (ps, vmmap, sample, xctrace).

Usage:
  scripts/capture_memory_profile.sh [options]

Options:
  --pid <pid>                 Target process id. If omitted, uses latest OrbitDock app PID.
  --sample-seconds <seconds>  sample duration (default: 5)
  --trace-seconds <seconds>   xctrace Allocations duration (default: 10, use 0 to disable)
  --out-dir <path>            output directory (default: /tmp/orbitdock-memory-profile-<timestamp>)
  -h, --help                  show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)
      pid="${2:-}"
      shift 2
      ;;
    --sample-seconds)
      sample_seconds="${2:-}"
      shift 2
      ;;
    --trace-seconds)
      trace_seconds="${2:-}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_integer() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "Invalid $name: $value (expected non-negative integer)" >&2
    exit 1
  fi
}

require_integer "sample-seconds" "$sample_seconds"
require_integer "trace-seconds" "$trace_seconds"

discover_latest_pid() {
  ps -axo pid,lstart,command | awk -v pattern="$process_pattern" '
    $0 ~ pattern { print $1 }
  ' | tail -n 1
}

if [[ -z "$pid" ]]; then
  pid="$(discover_latest_pid)"
fi

if [[ -z "$pid" ]]; then
  echo "Could not find OrbitDock process matching pattern: $process_pattern" >&2
  exit 1
fi

if ! kill -0 "$pid" 2>/dev/null; then
  echo "Process $pid is not running" >&2
  exit 1
fi

if [[ -z "$out_dir" ]]; then
  out_dir="/tmp/orbitdock-memory-profile-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$out_dir"

warn() {
  echo "WARN: $*" >&2
}

run_or_warn() {
  local description="$1"
  shift
  if ! "$@"; then
    warn "$description failed"
    return 1
  fi
  return 0
}

echo "Capturing OrbitDock memory profile"
echo "  pid: $pid"
echo "  out_dir: $out_dir"
echo "  sample_seconds: $sample_seconds"
echo "  trace_seconds: $trace_seconds"

ps -o pid,ppid,rss,vsz,%mem,etime,command -p "$pid" > "$out_dir/ps.txt"
run_or_warn "vmmap summary" vmmap -summary "$pid" > "$out_dir/vmmap-summary.txt"
run_or_warn "sample" sample "$pid" "$sample_seconds" 1 > "$out_dir/sample.txt" 2>&1

if [[ "$trace_seconds" -gt 0 ]]; then
  if command -v xctrace >/dev/null 2>&1; then
    if run_or_warn "xctrace record" xctrace record \
      --template 'Allocations' \
      --attach "$pid" \
      --time-limit "${trace_seconds}s" \
      --output "$out_dir/allocations.trace" >/dev/null 2>&1
    then
      run_or_warn "xctrace export" xctrace export \
        --input "$out_dir/allocations.trace" \
        --toc > "$out_dir/xctrace-toc.xml" 2>/dev/null
    fi
  else
    warn "xctrace not found; skipping allocation trace"
  fi
fi

footprint="$(awk '/Physical footprint:/ {print $3; exit}' "$out_dir/vmmap-summary.txt" 2>/dev/null || true)"
peak_footprint="$(awk '/Physical footprint \(peak\):/ {print $4; exit}' "$out_dir/vmmap-summary.txt" 2>/dev/null || true)"
malloc_small="$(awk '/MALLOC_SMALL[[:space:]]/ {print $0; exit}' "$out_dir/vmmap-summary.txt" 2>/dev/null || true)"
core_animation="$(awk '/CoreAnimation[[:space:]]/ {print $0; exit}' "$out_dir/vmmap-summary.txt" 2>/dev/null || true)"
iosurface="$(awk '/IOSurface[[:space:]]/ {print $0; exit}' "$out_dir/vmmap-summary.txt" 2>/dev/null || true)"

{
  echo "output_dir=$out_dir"
  echo "pid=$pid"
  echo "sample_seconds=$sample_seconds"
  echo "trace_seconds=$trace_seconds"
  [[ -n "$footprint" ]] && echo "physical_footprint=$footprint"
  [[ -n "$peak_footprint" ]] && echo "physical_footprint_peak=$peak_footprint"
  [[ -n "$core_animation" ]] && echo "core_animation_region=\"$core_animation\""
  [[ -n "$malloc_small" ]] && echo "malloc_small_region=\"$malloc_small\""
  [[ -n "$iosurface" ]] && echo "iosurface_region=\"$iosurface\""
  echo "artifacts:"
  echo "  - ps.txt"
  echo "  - vmmap-summary.txt"
  echo "  - sample.txt"
  if [[ -f "$out_dir/allocations.trace/.trace-toc" || -f "$out_dir/allocations.trace" ]]; then
    echo "  - allocations.trace"
  fi
  if [[ -f "$out_dir/xctrace-toc.xml" ]]; then
    echo "  - xctrace-toc.xml"
  fi
} > "$out_dir/capture-summary.txt"

echo
cat "$out_dir/capture-summary.txt"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  capture_memory_profile.sh [options]

Options:
  --pid <pid>                 Target process PID. If omitted, resolve latest OrbitDock PID.
  --process-name <name>       Process name for PID lookup (default: OrbitDock).
  --out-dir <path>            Output directory (default: /tmp/orbitdock-profile-<timestamp>).
  --sample-seconds <seconds>  Seconds for `sample` capture (default: 5, 0 disables).
  --trace-seconds <seconds>   Seconds for xctrace Allocations capture (default: 10, 0 disables).
  --run-leaks                 Run `leaks` capture.
  -h, --help                  Show this help.
USAGE
}

process_name="OrbitDock"
pid=""
out_dir=""
sample_seconds=5
trace_seconds=10
run_leaks=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid)
      pid="$2"
      shift 2
      ;;
    --process-name)
      process_name="$2"
      shift 2
      ;;
    --out-dir)
      out_dir="$2"
      shift 2
      ;;
    --sample-seconds)
      sample_seconds="$2"
      shift 2
      ;;
    --trace-seconds)
      trace_seconds="$2"
      shift 2
      ;;
    --run-leaks)
      run_leaks=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$pid" ]]; then
  if ! pid="$(pgrep -x "$process_name" | tail -n 1)"; then
    echo "Could not resolve PID for process '$process_name'." >&2
    exit 1
  fi
fi

if [[ -z "$out_dir" ]]; then
  timestamp="$(date +%Y%m%d-%H%M%S)"
  out_dir="/tmp/orbitdock-profile-${timestamp}"
fi

mkdir -p "$out_dir"

summary_file="$out_dir/capture-summary.txt"
{
  echo "OrbitDock memory capture"
  echo "timestamp: $(date -Iseconds)"
  echo "pid: $pid"
  echo "process_name: $process_name"
  echo "out_dir: $out_dir"
  echo "sample_seconds: $sample_seconds"
  echo "trace_seconds: $trace_seconds"
  echo "run_leaks: $run_leaks"
} > "$summary_file"

ps -o pid,ppid,rss,vsz,%mem,etime,command -p "$pid" > "$out_dir/ps.txt" 2> "$out_dir/ps.err" || true

if vmmap -summary "$pid" > "$out_dir/vmmap-summary.txt" 2> "$out_dir/vmmap-summary.err"; then
  echo "vmmap: ok" >> "$summary_file"
else
  echo "vmmap: failed (see vmmap-summary.err; this often needs elevated permissions)" >> "$summary_file"
fi

if [[ "$sample_seconds" -gt 0 ]]; then
  if sample "$pid" "$sample_seconds" 1 > "$out_dir/sample.txt" 2> "$out_dir/sample.err"; then
    echo "sample: ok" >> "$summary_file"
  else
    echo "sample: failed (see sample.err; this often needs elevated permissions)" >> "$summary_file"
  fi
fi

if [[ "$trace_seconds" -gt 0 ]]; then
  trace_path="$out_dir/allocations.trace"
  if xctrace record \
    --template "Allocations" \
    --attach "$pid" \
    --time-limit "${trace_seconds}s" \
    --output "$trace_path" > "$out_dir/xctrace-record.log" 2>&1; then
    echo "xctrace_record: ok" >> "$summary_file"
    if xctrace export --input "$trace_path" --toc > "$out_dir/xctrace-toc.xml" 2> "$out_dir/xctrace-toc.err"; then
      echo "xctrace_export_toc: ok" >> "$summary_file"
    else
      echo "xctrace_export_toc: failed (see xctrace-toc.err)" >> "$summary_file"
    fi
  else
    echo "xctrace_record: failed (see xctrace-record.log; this often needs elevated permissions)" >> "$summary_file"
  fi
fi

if [[ "$run_leaks" -eq 1 ]]; then
  if leaks "$pid" > "$out_dir/leaks.txt" 2> "$out_dir/leaks.err"; then
    echo "leaks: ok" >> "$summary_file"
  else
    echo "leaks: failed (see leaks.err; this often needs elevated permissions)" >> "$summary_file"
  fi
fi

echo "Capture complete: $out_dir"
